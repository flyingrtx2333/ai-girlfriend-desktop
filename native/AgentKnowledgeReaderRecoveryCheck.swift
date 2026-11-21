import AppKit

@MainActor extension AppDelegate {
    struct KnowledgeReaderFixture: Codable {
        var first: String, second: String, firstWindow: String, secondWindow: String
        var rootA: String, rootB: String, fileA: String, fileB: String, bookPointer: String
        var card: AgentWorkspaceRecovery.Page, index: AgentWorkspaceRecovery.Page
        var bookHash: String, sourceHash: String, changedHash: String
        var statsA: AgentIndexStats, statsB: AgentIndexStats
        var drafts: [String: String]
    }
    func runKnowledgeReaderRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务存储不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("知识阅读恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("knowledge-reader-fixture.json"), input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("reader-input.json"))) as! [String: String]
            let journal = AgentWorkspaceRecovery(profile: store.directory)
            func child() throws -> ControlWindow { guard let value = taskControls.first(where: { $0.taskWindowNumber == 2 }) else { throw PetError("第二个任务窗口未恢复") }; return value }
            func card() throws -> AgentKnowledgeCardWindow { guard let value = control.knowledgePageHost.recoveryEditors.compactMap({ $0 as? AgentKnowledgeCardWindow }).last else { throw PetError("卡片父页未恢复") }; return value }
            func index() throws -> AgentKnowledgeWindow { guard let value = try child().knowledgePageHost.recoveryEditors.compactMap({ $0 as? AgentKnowledgeWindow }).last else { throw PetError("检索父页未恢复") }; return value }
            func source(_ value: AgentKnowledgeSourcePage?) throws -> AgentKnowledgeSourcePage { guard let value else { throw PetError("知识来源页不存在") }; return value }
            func snapshot(_ id: String) throws -> AgentWorkspaceRecovery.Window { guard let value = try journal.loadWindow(id)?.value else { throw PetError("知识窗口记录不存在") }; return value }
            func flush() async throws { guard await flushWorkspaceWindows() else { throw PetError("知识窗口未保存") } }
            func eventually(_ condition: () -> Bool) async -> Bool { for _ in 0..<160 { if condition() { return true }; await wait(0.03) }; return condition() }
            func page(_ view: AgentKnowledgeCardWindow) throws -> AgentWorkspaceRecovery.Page { guard let value = try view.captureWorkspaceRecovery() else { throw PetError("卡片状态尚未就绪") }; return value }
            func page(_ view: AgentKnowledgeWindow) throws -> AgentWorkspaceRecovery.Page { guard let value = try view.captureWorkspaceRecovery() else { throw PetError("检索状态尚未就绪") }; return value }
            func state(_ view: AgentKnowledgeSourcePage) throws -> AgentKnowledgeSourcePage.RecoveryState { guard let value = try view.captureWorkspaceRecovery() else { throw PetError("来源页已关闭") }; return value }
            func sourceState(_ card: AgentKnowledgeCardWindow) throws -> AgentKnowledgeCardWindow.RecoveryState { try AgentKnowledgeCardWindow.recoveryState(page(card)) }
            func sourceState(_ index: AgentKnowledgeWindow) throws -> AgentKnowledgeWindow.RecoveryState { try AgentKnowledgeWindow.recoveryState(page(index)) }
            let fixture: KnowledgeReaderFixture
            if stage == "seed" {
                let rootA = output.appendingPathComponent("project-a"), rootB = output.appendingPathComponent("project-b"), fileA = rootA.appendingPathComponent("README.md"), fileB = rootB.appendingPathComponent("README.md")
                let a = tasks.create(title: "知识卡片恢复", workspace: rootA.path), b = tasks.create(title: "项目检索恢复", workspace: rootB.path)
                for id in [a, b] { tasks.update(id) { $0.draft = "PUBLIC_TASK_DRAFT_417 中文😀" } }
                try tasks.organization.register(rootA.path, mode: .coding); try tasks.organization.register(rootB.path, mode: .coding)
                let indexA = try AgentProjectIndex(workspace: rootA.path, storage: tasks.directory), indexB = try AgentProjectIndex(workspace: rootB.path, storage: tasks.directory)
                let indexed = try await indexA.run(paths: nil); _ = try await indexB.run(paths: nil)
                let hash = try AgentFiles(workspace: rootA.path).fileHash(fileA), task = tasks.task(a)!, scope = try tasks.knowledgeCards.scope(task)
                let original = AgentKnowledgeCard(title: "PUBLIC_CARD_TITLE_417 中文😀", kind: .architecture, body: input["publishedBody"]!, sources: [.init(path: "README.md", line: 20, endLine: 220, sha256: hash)], manual: true)
                let book = AgentKnowledgeCardBook(workspace: scope.root, branch: scope.branch, language: "zh", sourceRevision: indexed.index.revision, cards: [original])
                try tasks.knowledgeCards.publish(book, task: task, expected: tasks.knowledgeCards.book(task).1)
                let pointer = try tasks.knowledgeCards.pointer(scope, language: "zh"), originalBook = try Data(contentsOf: pointer)
                try originalBook.write(to: output.appendingPathComponent("original-book.json"))
                control.showAgentTask(a); control.window?.setFrame(NSRect(x: 50, y: 120, width: 1200, height: 774), display: true); control.showKnowledgeCards(taskID: a)
                let cards = try card(); try cards.checkRecovery(title: input["draftTitle"], body: input["draftBody"], target: "PUBLIC_CARD_LINE_21 中文😀", y: 240, titleSelection: NSRange(location: 7, length: 2))
                try cards.checkRecovery(action: "source"); let cardSource = try source(cards.sourceWindow)
                try cardSource.checkView(target: "PUBLIC_READER_LINE_90 中文😀", y: 260)
                openTaskWindow(b, from: control); let other = try child(); other.window?.setFrame(NSRect(x: 1050, y: 180, width: 800, height: 550), display: true); other.showAgentKnowledge()
                guard let catalog = other.knowledgePageHost.currentController as? AgentRepoWikiWindow else { throw PetError("项目目录未显示") }
                _ = await eventually { catalog.checkState["loading"] as? Bool == false }
                try catalog.checkOpen(workspace: rootB.path, action: "search")
                let search = try index(); guard await search.checkRecoverySearch("PUBLIC_READER_LINE_120", open: false) else { throw PetError("真实项目检索没有结果") }
                try search.checkRecoveryView(target: "PUBLIC_READER_LINE_150 中文😀", y: 220, querySelection: NSRange(location: 5, length: 3))
                search.checkRecoveryOpenSource()
                let indexSource = try source(search.sourceWindow); try indexSource.checkView(target: "PUBLIC_READER_LINE_200 中文😀", y: 430)
                try await flush(); let cardPage = try page(cards), indexPage = try page(search)
                guard let firstWindow = control.workspaceSession?.id, let secondWindow = other.workspaceSession?.id else { throw PetError("知识窗口编号未保存") }
                guard let statsA = try indexA.snapshot(), let statsB = try indexB.snapshot() else { throw PetError("索引实际快照不存在") }
                fixture = .init(first: a, second: b, firstWindow: firstWindow, secondWindow: secondWindow, rootA: rootA.path, rootB: rootB.path, fileA: fileA.path, fileB: fileB.path, bookPointer: pointer.path,
                    card: cardPage, index: indexPage, bookHash: AgentFiles.hash(originalBook), sourceHash: hash, changedHash: input["changedHash"]!, statsA: statsA, statsB: statsB, drafts: [a: tasks.task(a)?.draft ?? "", b: tasks.task(b)?.draft ?? ""])
                checks["twoTaskWindowsKeepTheirOwnKnowledgeIdentity"] = control.agentTaskID == a && other.agentTaskID == b && firstWindow != secondWindow
                checks["invalidButCompleteCardDraftSavedBeforeQuit"] = try sourceState(cards).body == input["draftBody"] && sourceState(cards).title == input["draftTitle"] && cardPage.dirty && input["draftBody"]!.utf8.count > 4000
                checks["cardOriginalVersionAndFieldCursorSaved"] = try sourceState(cards).revision == fixture.bookHash && sourceState(cards).fields["title"] == .init(location: 7, length: 2)
                checks["bothSourcesAreReadonlyHostedPagesWithDifferentOwners"] = cardSource.checkState["editable"] as? Bool == false && indexSource.checkState["editable"] as? Bool == false && cardSource.settingsHostWindow === control.window && indexSource.settingsHostWindow === other.window && cardSource.checkState["taskID"] as? String == a && indexSource.checkState["taskID"] as? String == b
                checks["sameSourceBytesDoNotMergeWorkspaceOwnership"] = try state(cardSource).hash == state(indexSource).hash && state(cardSource).root != state(indexSource).root
                checks["bothSourcePositionsAreSavedIndependently"] = try (state(cardSource).viewport?.y ?? 0) > 0 && (state(indexSource).viewport?.y ?? 0) > 0 && state(cardSource).viewport != state(indexSource).viewport
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(fixture).write(to: fixtureURL)
            } else {
                fixture = try JSONDecoder().decode(KnowledgeReaderFixture.self, from: Data(contentsOf: fixtureURL)); restoreAdditionalWorkspaceWindows(); try await flush()
                if stage == "observe" {
                    checks["manualObserveKeepsOriginalPrimaryWindow"] = control.workspaceSession?.id == fixture.firstWindow
                    checks["manualObserveKeepsSecondaryOrItsExplicitClose"] = try snapshot(fixture.secondWindow).closed || taskControls.contains { $0.workspaceSession?.id == fixture.secondWindow }
                } else if stage == "future" {
                    let before = try snapshot(fixture.firstWindow).knowledge
                    checks["unknownCardSourceLeavesOnlyItsWindowCold"] = control.workspaceSession?.hasPendingKnowledge == true && control.knowledgePageHost.recoveryEditors.isEmpty
                    control.showAgentKnowledge(); try await flush()
                    checks["retryPreservesUnknownCardPageBytesExactly"] = try before == (snapshot(fixture.firstWindow).knowledge) && control.workspaceSession?.hasPendingKnowledge == true
                    let search = try index(), indexSource = try source(search.sourceWindow), expected = try AgentKnowledgeWindow.recoveryState(fixture.index)
                    checks["otherWindowRestoresQueryAndSourceWhileCardIsCold"] = try search.search.stringValue == expected.query && (state(indexSource)) == expected.source
                    checks["coldCardDoesNotReplaceSelectedTaskOrOtherWindow"] = try control.agentTaskID == fixture.first && (child().agentTaskID) == fixture.second
                } else if stage == "closed" {
                    checks["closedKnowledgeDoesNotResurrect"] = try snapshot(fixture.firstWindow).knowledge == nil && control.knowledgePageHost.recoveryEditors.isEmpty
                    checks["explicitSecondaryCloseDoesNotReopenWindow"] = try snapshot(fixture.secondWindow).closed && taskControls.allSatisfy { $0.taskWindowNumber != 2 }
                    guard let task = tasks.task(fixture.first) else { throw PetError("卡片原任务丢失") }
                    checks["explicitSaveKeptNewCardAndRetainedHistory"] = try tasks.knowledgeCards.book(task).0?.cards.first?.body == input["savedBody"] && tasks.knowledgeCards.book(task).0?.cards.first?.title == input["savedTitle"]
                } else {
                    let cards = try card(), search = try index(), cardSource = try source(cards.sourceWindow), indexSource = try source(search.sourceWindow)
                    let originalCard = try AgentKnowledgeCardWindow.recoveryState(fixture.card), originalIndex = try AgentKnowledgeWindow.recoveryState(fixture.index), current = try sourceState(cards), currentIndex = try sourceState(search)
                    checks["completeInvalidCardBodyAndTitleSurviveProcesses"] = current.body == originalCard.body && current.title == originalCard.title && current.dirty && current.book?.cards.first?.hash == originalCard.book?.cards.first?.hash
                    checks["originalBookScopeLanguageAndFieldPositionSurvive"] = current.scope.root == originalCard.scope.root && current.scope.branch == originalCard.scope.branch && current.language == originalCard.language && current.revision == originalCard.revision && current.fields == originalCard.fields && current.active == originalCard.active
                    checks["cardBodySelectionAndScrollSurvive"] = current.views == originalCard.views
                    checks["searchResultsQuerySelectionAndScopeSurvive"] = currentIndex.query == originalIndex.query &&
                        currentIndex.submittedQuery == originalIndex.submittedQuery && currentIndex.root == originalIndex.root &&
                        currentIndex.selected == originalIndex.selected && currentIndex.hits.map(\.path) == originalIndex.hits.map(\.path) &&
                        currentIndex.querySelection == originalIndex.querySelection
                    checks["otherSourceRetainsExactOriginalState"] = try state(indexSource) == originalIndex.source && indexSource.checkState["loaded"] as? Bool == true
                    checks["bothTaskOwnersStayInTheirOriginalWindows"] = try control.agentTaskID == fixture.first && (child().agentTaskID) == fixture.second
                    if stage == "missing" {
                        checks["missingSourceShowsReadonlyErrorAndKeepsOriginalProgress"] = try cardSource.checkState["loaded"] as? Bool == false && cardSource.checkState["text"] as? String == "" && (state(cardSource)) == originalCard.source
                        try cardSource.checkView(action: "retry"); checks["missingSourceRetryKeepsPendingState"] = try state(cardSource) == originalCard.source && cardSource.checkState["loaded"] as? Bool == false
                    } else if stage == "retry" {
                        checks["returnedSourceRestoresOriginalProgress"] = try state(cardSource) == originalCard.source && cardSource.checkState["loaded"] as? Bool == true
                        try cards.checkRecovery(action: "save")
                        checks["invalidSaveKeepsWholeDraftAndOriginalBook"] = try sourceState(cards).body == input["draftBody"] && sourceState(cards).dirty && tasks.knowledgeCards.book(tasks.task(fixture.first)!).1 == fixture.bookHash
                        let original = originalCard.book!.cards.first!
                        _ = try tasks.knowledgeCards.replaceCard(task: tasks.task(fixture.first)!, id: original.id, body: "PUBLIC_EXTERNAL_CARD_CHANGE_628", title: nil, expectedCard: original.hash, citations: nil, expectedBook: fixture.bookHash)
                        let external = try tasks.knowledgeCards.book(tasks.task(fixture.first)!).1; try cards.checkRecovery(action: "save")
                        checks["externalBookChangeBlocksSaveWithoutLosingDraft"] = try tasks.knowledgeCards.book(tasks.task(fixture.first)!).1 == external && sourceState(cards).body == input["draftBody"] && sourceState(cards).dirty
                        tasks.update(fixture.first) { $0.workspace = fixture.rootB }; try tasks.save(fixture.first)
                        try cards.checkRecovery(action: "save"); try cardSource.checkView(action: "retry")
                        checks["identicalFileHashCannotBypassChangedTaskRoot"] = try cardSource.checkState["loaded"] as? Bool == false && (state(cardSource)) == originalCard.source && cards.state.stringValue.contains("工作区")
                        tasks.update(fixture.first) { $0.workspace = fixture.rootA }; try tasks.save(fixture.first); try cardSource.checkView(action: "retry")
                        checks["liveScopeFailureThenRetryRestoresOriginalPosition"] = try state(cardSource) == originalCard.source && cardSource.checkState["loaded"] as? Bool == true
                        var options = try tasks.knowledgeCards.options(workspace: fixture.rootA); options.language = "en"; try tasks.knowledgeCards.setOptions(options, workspace: fixture.rootA, expected: tasks.knowledgeCards.settings().1)
                        try cards.checkRecovery(action: "save"); checks["changedLanguageCannotRedirectOldDraft"] = try cards.state.stringValue.contains("语言") && (sourceState(cards)).body == input["draftBody"]
                        options.language = "zh"; try tasks.knowledgeCards.setOptions(options, workspace: fixture.rootA, expected: tasks.knowledgeCards.settings().1)
                        try JSONSerialization.data(withJSONObject: ["hash": external], options: [.sortedKeys]).write(to: output.appendingPathComponent("external-book-proof.json"))
                    } else if stage == "changed" {
                        checks["changedBytesOutsideSnippetKeepOriginalPendingPosition"] = try cardSource.checkState["loaded"] as? Bool == false && (state(cardSource)) == originalCard.source
                        try cardSource.checkView(action: "latest"); let adopted = try state(cardSource)
                        checks["explicitCurrentVersionAdoptsOnlyThisSource"] = adopted.hash == fixture.changedHash && adopted.viewport?.selections.first?.length == 0 && adopted.viewport?.y == 0 && cardSource.checkState["loaded"] as? Bool == true
                        checks["otherTaskSourceAndCardDraftStayUnchanged"] = try state(indexSource) == originalIndex.source && sourceState(cards).body == input["draftBody"] && sourceState(cards).dirty
                    } else if stage == "original" {
                        checks["returnedOriginalDoesNotSilentlyAdoptDifferentHash"] = try cardSource.checkState["loaded"] as? Bool == false && (state(cardSource)).hash == fixture.changedHash
                        try cardSource.checkView(action: "latest"); control.window?.makeKeyAndOrderFront(nil); control.knowledgePageHost.checkBack(); await wait(0.05)
                        checks["explicitSourceBackKeepsOnlyOriginalCardDraft"] = try cards.sourceWindow == nil && (sourceState(cards)).body == input["draftBody"] && cards.dirty
                        checks["sourceBackRestoresActualTitleFocusAndOriginalSelection"] = await eventually { cards.lastContentFocus == "title" && cards.titleField.currentEditor() === control.window?.firstResponder && (cards.titleField.currentEditor() as? NSTextView)?.selectedRange() == originalCard.fields["title"]?.range }
                        control.knowledgePageHost.focusCurrentPage()
                        checks["hostRefocusKeepsOwnedTitleFieldEditor"] = cards.titleField.currentEditor() === control.window?.firstResponder && (cards.titleField.currentEditor() as? NSTextView)?.selectedRange() == originalCard.fields["title"]?.range
                        try cards.checkRecovery(title: input["savedTitle"], body: input["savedBody"]); try cards.checkRecovery(action: "save")
                        checks["explicitSaveUsesOriginalCardAndBookAfterRepair"] = try !cards.dirty && (tasks.knowledgeCards.book(tasks.task(fixture.first)!).0?.cards.first?.body) == input["savedBody"]
                        control.knowledgePageHost.checkBack(); let other = try child(); other.window?.makeKeyAndOrderFront(nil); other.knowledgePageHost.checkBack(); await wait(0.05)
                        checks["explicitIndexSourceBackKeepsQueryAndParent"] = search.sourceWindow == nil && search.search.stringValue == originalIndex.query && other.knowledgePageHost.currentController === search
                        checks["sourceBackRestoresActualQueryFocusAndOriginalSelection"] = await eventually { search.search.currentEditor() === other.window?.firstResponder && (search.search.currentEditor() as? NSTextView)?.selectedRange() == originalIndex.querySelection?.range }
                        other.knowledgePageHost.focusCurrentPage()
                        checks["hostRefocusKeepsOwnedQuerySelection"] = search.search.currentEditor() === other.window?.firstResponder && (search.search.currentEditor() as? NSTextView)?.selectedRange() == originalIndex.querySelection?.range
                        try search.checkRecoveryView(target: "PUBLIC_READER_LINE_150 中文😀", y: 220)
                        other.showAgentTask(fixture.second); other.showAgentKnowledge()
                        checks["cachedIndexRestoresActualPreviewFocus"] = await eventually { other.window?.firstResponder === search.preview && search.lastContentFocus == "preview" }
                        other.knowledgePageHost.checkBack(); try await flush()
                        checks["explicitParentBackClearsBothKnowledgeRecords"] = try snapshot(fixture.firstWindow).knowledge == nil && snapshot(fixture.secondWindow).knowledge == nil
                        other.window?.performClose(nil); checks["secondaryWindowClosesNormallyWithJournalMarkedClosed"] = await eventually { !taskControls.contains { $0.taskWindowNumber == 2 } }
                    } else { throw PetError("未知知识阅读恢复阶段") }
                }
            }
            try await flush()
            if stage != "observe" {
                checks["taskInputsRetainTheirOriginalOwners"] = fixture.drafts.allSatisfy { tasks.task($0.key)?.draft == $0.value }
                let statsA = try AgentProjectIndex(workspace: fixture.rootA, storage: tasks.directory).snapshot(), statsB = try AgentProjectIndex(workspace: fixture.rootB, storage: tasks.directory).snapshot()
                checks["restoreDoesNotReplaySearchOrMutatingIndexWork"] = statsA?.revision == fixture.statsA.revision && statsA?.updated == fixture.statsA.updated && statsB?.revision == fixture.statsB.revision && statsB?.updated == fixture.statsB.updated
            }
            checks["otherProjectOriginalFileAlwaysPreserved"] = try AgentFiles(workspace: fixture.rootB).fileHash(URL(fileURLWithPath: fixture.fileB)) == fixture.sourceHash
            report["stage"] = stage; report["windows"] = try journal.list().windows.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.value)) }
            report["hosts"] = taskControls.map { ["number": $0.taskWindowNumber, "taskID": $0.agentTaskID ?? "", "knowledge": $0.knowledgePageHost.checkState()] as [String: Any] }
            report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        let binary = Bundle.main.executableURL!; report["appPID"] = getpid(); report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
        report["modelRequests"] = requests; report["checks"] = checks
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "knowledge-reader-ui-ready.json" : "knowledge-reader-report.json"))
    }
}
