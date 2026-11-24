import AppKit

@MainActor extension AgentKnowledgeCardWindow {
    func run(_ operation: @escaping () async throws -> Void) {
        guard !busy, reviewWindow?.hasPendingOperation != true else { return }; busy = true; generate.isEnabled = false
        job = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; reload() }
            do { try await operation() }
            catch { if !Task.isCancelled, let workspace = task?.workspace { cards.notices[workspace] = error.localizedDescription } }
        }
    }
    func connect(for operation: String) async throws {
        guard task?.workspace != nil else { throw PetError("请先选择工作区") }
        let tools = AgentTools(store: store, taskID: taskID), call = AgentToolCall(id: UUID().uuidString, name: "index_project", arguments: "{}")
        let directory = try tools.gitDirectory(for: call)
        if let reason = try tools.approvalReason(for: call, gitDirectory: directory) {
            try await AgentProjectKnowledgeApproval.request(from: self, operation: operation, tools: tools, call: call, directory: directory, reason: reason)
        }
        _ = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation()
    }
    @objc func generateCards() {
        if needsConnection { reloadCards(); return }
        do { try requireOriginalCardScope() } catch { state.stringValue = error.localizedDescription; return }
        guard discard() else { return }
        if value?.cards.contains(where: \.manual) == true {
            let alert = AgentConfirmation(); alert.messageText = "重新核对已编辑的卡片？"; alert.informativeText = "将依据当前源码重新生成，旧版本可恢复。"; alert.addButton(withTitle: "重新生成"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let language = selectedLanguage, instruction = focus.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        run { [self] in
            try await connect(for: "生成知识卡片")
            _ = try await cards.generate(sourceID: taskID, language: language, focus: instruction)
        }
    }
    @objc func reloadCards() { guard discard() else { return }; resetRecoverySnapshot(); run { [self] in try await connect(for: "刷新知识卡片") } }
    var latestTask: AgentTaskRecord? {
        guard let task, let scope = try? cards.scope(task) else { return nil }
        return store.tasks.filter { $0.kind == AgentKnowledgeCards.kind && $0.workspace == scope.root && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == selectedLanguage && !$0.archived }.max { $0.updated < $1.updated }
    }
    @objc func viewTask() { do { try requireOriginalCardScope(); if let id = activeTask?.id ?? latestTask?.id ?? value?.taskID { onOpenTask?(id) } } catch { state.stringValue = error.localizedDescription } }
    @objc func languageChanged() {
        defer { onWorkspaceChange?() }
        do { try requireOriginalCardScope(checkLanguage: false) } catch { language.selectItem(at: value?.language == "en" ? 1 : 0); state.stringValue = error.localizedDescription; return }
        guard discard() else { language.selectItem(at: value?.language == "en" ? 1 : 0); return }
        resetRecoverySnapshot()
        saveOptions()
    }
    @objc func optionsChanged(_ sender: NSButton) {
        if sender.state == .on && (sender === automatic || sender === exporting) {
            let alert = AgentConfirmation(); alert.messageText = sender === automatic ? "启用自动更新？" : "启用自动导出？"
            alert.informativeText = sender === automatic ? "源码变化后使用此任务的模型生成卡片，会产生模型用量。存在手动编辑时会提示审阅。" : "卡片保存后写入当前项目的 " + ((try? cards.sharingPath(language: selectedLanguage)) ?? "知识目录") + "，可随项目提交。外部改动需先导入。"
            alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { sender.state = .off; return }
            sender.state = .on
        }
        saveOptions()
    }
    func saveOptions() {
        guard let workspace = task?.workspace else { return }
        if openedScope != nil { do { try requireOriginalCardScope() } catch { state.stringValue = error.localizedDescription; return } }
        let language = selectedLanguage, citation = citation.state == .on, automatic = automatic.state == .on, exporting = exporting.state == .on
        run { [self] in
            try await connect(for: "应用知识卡片设置")
            guard let current = task?.workspace, try AgentFiles(workspace: current).root == AgentFiles(workspace: workspace).root else { throw PetError("知识卡片所属工作区已变化，设置未写入") }
            var options = try cards.options(workspace: workspace)
            options.language = language; options.citation = citation; options.autoUpdate = automatic; options.autoExport = exporting; options.sourceTaskID = taskID
            try cards.setOptions(options, workspace: workspace, expected: cards.settings().1)
            if exporting, let task, try cards.book(task, language: language).0 != nil { _ = try cards.exportBook(task, language: language) }
        }
    }
    @objc func saveCard() {
        presentingWindow?.makeFirstResponder(nil)
        guard let task, let selected else { return }
        do {
            try requireOriginalCardScope()
            _ = try cards.replaceCard(task: task, id: selected.id, body: preview.string, title: titleField.stringValue, expectedCard: selected.hash, citations: nil, expectedBook: revision)
            dirty = false; hasRestoredSnapshot = false; reload(); onWorkspaceChange?()
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc func exportCards() {
        guard let task, discard() else { return }
        do { try requireOriginalCardScope(); guard try cards.book(task, language: selectedLanguage).1 == revision else { throw PetError("卡片已变化，请先刷新核对") }; let names = try cards.exportBook(task, language: selectedLanguage); state.stringValue = "已导出 \(names.count - 1) 张 · " + (try cards.sharingPath(language: selectedLanguage)) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func presentCardReview(_ review: AgentKnowledgeReviewWindow) {
        guard reviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return }
        reviewWindow?.close(); retainCardReview(review)
        presentSettingsChild(review); onWorkspaceChange?()
    }
    private func retainCardReview(_ review: AgentKnowledgeReviewWindow) {
        reviewWindow = review
        review.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        review.onClose = { [weak self, weak review] in
            guard let self, reviewWindow === review else { return }
            reviewWindow = nil; onWorkspaceChange?()
        }
    }
    func restoreCardVersionReview(_ position: AgentKnowledgeVersionPosition?) throws {
        guard let position else { return }
        let review = try makeCardVersionReview(language: position.context.language)
        try review.restoreVersionPosition(position)
        retainCardReview(review)
    }
    private func reviewedCardTask(_ original: AgentTaskRecord, readOnly: Bool) throws -> AgentTaskRecord {
        guard let current = task, !current.archived, !dirty, current.workspace == original.workspace, current.mode == original.mode, current.permission == original.permission,
              try store.agents.limits(current, store: store).readOnly == readOnly else { throw PetError("任务范围、权限或卡片草稿已变化，请重新预览") }
        return current
    }
    @objc func importCards() {
        do { try requireOriginalCardScope() } catch { state.stringValue = error.localizedDescription; return }
        guard discard() else { return }
        let language = selectedLanguage
        run { [self] in
            try await connect(for: "预览导入知识卡片"); guard task != nil else { return }
            let review = AgentKnowledgeReviewWindow(title: "导入知识卡片", action: "导入", scope: language == "zh" ? "简体中文" : "English", load: { [weak self] _, _ in
                guard let self, let original = self.task, !self.dirty else { throw PetError("任务或卡片草稿已变化，请重新预览") }
                let readOnly = try self.store.agents.limits(original, store: self.store).readOnly
                let value = try self.cards.previewImport(original, language: language)
                return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.book.branch, language: language), impact: "\(value.book.cards.count) 张卡片；替换当前语言，原版本保留。来源变化的卡片不会自动引用。", items: AgentKnowledgeReviewSnapshot.cardItems(value.book)) { [weak self] in
                    guard let self else { throw PetError("知识卡片页面已关闭") }
                    let current = try self.reviewedCardTask(original, readOnly: readOnly)
                    try self.cards.importBook(value, task: current)
                    return "已导入 \(value.book.cards.count) 张卡片"
                }
            }, onApplied: { [weak self] message in self?.resetRecoverySnapshot(); self?.reload(); self?.state.stringValue = message })
            presentCardReview(review)
        }
    }
    @objc func restoreVersion() {
        do { try requireOriginalCardScope() } catch { state.stringValue = error.localizedDescription; return }
        guard discard() else { return }
        do { presentCardReview(try makeCardVersionReview(language: selectedLanguage)) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func makeCardVersionReview(language: String) throws -> AgentKnowledgeReviewWindow {
        guard let task else { throw PetError("卡片原任务不可用") }
        let context = try AgentKnowledgeVersionContext(.cards, store: store, taskID: taskID, language: language)
        let versions = try cards.history(task, language: language).filter { $0.id != value?.id }
        guard !versions.isEmpty else { throw PetError("暂无其他版本") }
        let choices = versions.map { AgentKnowledgeReviewVersion(id: $0.id, title: AgentKnowledgeReviewSnapshot.versionTitle($0.created, count: "\($0.cards.count) 张"), detail: String($0.id.prefix(8))) }
        return AgentKnowledgeReviewWindow(title: "恢复知识卡片", action: "恢复", scope: language == "zh" ? "简体中文" : "English", versions: choices, context: context, load: { [weak self] index, _ in
            guard let self, let original = self.task, !dirty, let index, versions.indices.contains(index) else { throw PetError("请选择实际存在的卡片版本") }
            try context.require(store)
            let version = versions[index], expected = try cards.book(original, language: language).1
            let readOnly = try store.agents.limits(original, store: store).readOnly
            return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(version.branch, language: language),
                impact: "\(version.cards.count) 张卡片；替换当前语言，原版本保留。恢复后使用前请核对源码。",
                items: AgentKnowledgeReviewSnapshot.cardItems(version), targetSignature: expected) { [weak self] in
                guard let self else { throw PetError("知识卡片页面已关闭") }
                try requireOriginalCardScope()
                let current = try reviewedCardTask(original, readOnly: readOnly)
                try cards.restore(version, task: current, expected: expected)
                return "已恢复 \(version.cards.count) 张卡片"
            }
        }, onApplied: { [weak self] message in self?.resetRecoverySnapshot(); self?.reload(); self?.state.stringValue = message })
    }
    @objc func openSource() {
        guard let task, let selected, selected.sources.indices.contains(sources.indexOfSelectedItem) else { return }
        do {
            try requireOriginalCardScope()
            let source = selected.sources[sources.indexOfSelectedItem], files = try AgentFiles(workspace: task.workspace)
            guard !AgentFiles.sensitive(source.path), try AgentProjectIndex(workspace: task.workspace, storage: store.directory).contains(source.path) else { throw PetError("源码不在当前项目索引中") }
            let page = try AgentKnowledgeSourcePage(store: store, taskID: taskID, file: files.resolve(source.path), offset: max(1, source.line - 3), limit: min(200, source.endLine - source.line + 10), maximum: 512_000, citationHash: source.sha256, line: source.line)
            sourceOwner = selected; retainSource(page); presentSettingsChild(page); onWorkspaceChange?()
        } catch { state.stringValue = error.localizedDescription }
    }
}
