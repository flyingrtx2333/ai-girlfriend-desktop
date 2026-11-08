import AppKit

@MainActor extension AgentKnowledgeCardWindow {
    func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; generate.isEnabled = false
        job = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; reload() }
            do { try await operation() }
            catch { if !Task.isCancelled, let workspace = task?.workspace { cards.notices[workspace] = error.localizedDescription } }
        }
    }
    func connect() async throws {
        guard task?.workspace != nil else { throw PetError("请先选择工作区") }
        let tools = AgentTools(store: store, taskID: taskID), call = AgentToolCall(id: UUID().uuidString, name: "index_project", arguments: "{}")
        let directory = try tools.gitDirectory(for: call)
        if let reason = try tools.approvalReason(for: call, gitDirectory: directory) {
            let alert = NSAlert(); alert.messageText = "连接项目知识"; alert.informativeText = reason; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { throw PetError("已取消") }
            if let directory { store.update(taskID) { $0.gitDirectory = directory } }
        }
        _ = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation()
    }
    @objc func generateCards() {
        guard discard() else { return }
        if value?.cards.contains(where: \.manual) == true {
            let alert = NSAlert(); alert.messageText = "重新核对已编辑的卡片？"; alert.informativeText = "将依据当前源码重新生成，旧版本可恢复。"; alert.addButton(withTitle: "重新生成"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run { [self] in try await connect(); _ = try cards.generate(sourceID: taskID, language: selectedLanguage, focus: focus.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    @objc func reloadCards() { guard discard() else { return }; run { [self] in try await connect() } }
    var latestTask: AgentTaskRecord? {
        guard let task, let scope = try? cards.scope(task) else { return nil }
        return store.tasks.filter { $0.kind == AgentKnowledgeCards.kind && $0.workspace == scope.root && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == selectedLanguage && !$0.archived }.max { $0.updated < $1.updated }
    }
    @objc func viewTask() { if let id = activeTask?.id ?? latestTask?.id ?? value?.taskID { onOpenTask?(id) } }
    @objc func languageChanged() {
        guard discard() else { language.selectItem(at: value?.language == "en" ? 1 : 0); return }
        saveOptions()
    }
    @objc func optionsChanged(_ sender: NSButton) {
        if sender.state == .on && (sender === automatic || sender === exporting) {
            let alert = NSAlert(); alert.messageText = sender === automatic ? "启用自动更新？" : "启用自动导出？"
            alert.informativeText = sender === automatic ? "源码变化后使用此任务的模型生成卡片，会产生模型用量。存在手动编辑时会提示审阅。" : "卡片保存后写入当前项目的 " + ((try? cards.sharingPath(language: selectedLanguage)) ?? "知识目录") + "，可随项目提交。外部改动需先导入。"
            alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { sender.state = .off; return }
        }
        saveOptions()
    }
    func saveOptions() {
        guard let workspace = task?.workspace else { return }
        let language = selectedLanguage, citation = citation.state == .on, automatic = automatic.state == .on, exporting = exporting.state == .on
        run { [self] in
            try await connect()
            var options = try cards.options(workspace: workspace)
            options.language = language; options.citation = citation; options.autoUpdate = automatic; options.autoExport = exporting; options.sourceTaskID = taskID
            try cards.setOptions(options, workspace: workspace, expected: cards.settings().1)
            if exporting, let task, try cards.book(task, language: language).0 != nil { _ = try cards.exportBook(task, language: language) }
        }
    }
    @objc func saveCard() {
        window?.makeFirstResponder(nil)
        guard let task, let selected else { return }
        do {
            _ = try cards.replaceCard(task: task, id: selected.id, body: preview.string, title: titleField.stringValue, expectedCard: selected.hash, citations: nil, expectedBook: revision)
            dirty = false; reload()
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc func exportCards() {
        guard let task, discard() else { return }
        do { let names = try cards.exportBook(task, language: selectedLanguage); state.stringValue = "已导出 \(names.count - 1) 张 · " + (try cards.sharingPath(language: selectedLanguage)) }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc func importCards() {
        guard discard() else { return }
        run { [self] in
            try await connect(); guard let task else { return }
            let value = try cards.previewImport(task, language: selectedLanguage)
            let alert = NSAlert(); alert.messageText = "导入 \(value.book.cards.count) 张项目卡片？"; alert.informativeText = "当前版本可恢复。来源变化的卡片不会自动引用。"
            alert.accessoryView = textPreview(value.book.cards.map { "# " + $0.title + "\n" + $0.body }.joined(separator: "\n\n"))
            alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; try cards.importBook(value, task: task)
        }
    }
    @objc func restoreVersion() {
        guard let task, discard() else { return }
        do {
            let versions = try cards.history(task, language: selectedLanguage).filter { $0.id != value?.id }
            guard !versions.isEmpty else { throw PetError("暂无其他版本") }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28)), formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .medium
            picker.addItems(withTitles: versions.map { formatter.string(from: $0.created) + " · \($0.cards.count) 张" })
            let alert = NSAlert(); alert.messageText = "选择要恢复的版本"; alert.accessoryView = picker; alert.addButton(withTitle: "预览"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let version = versions[picker.indexOfSelectedItem], confirm = NSAlert(); confirm.messageText = "恢复此版本？"; confirm.accessoryView = textPreview(version.cards.map { "# " + $0.title + "\n" + $0.body }.joined(separator: "\n\n")); confirm.addButton(withTitle: "恢复"); confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }; try cards.restore(version, task: task, expected: revision); reload()
        } catch { state.stringValue = error.localizedDescription }
    }
    func textPreview(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260)), view = NSTextView(frame: scroll.bounds)
        view.isEditable = false; view.isRichText = false; view.font = .systemFont(ofSize: 12); view.string = text; view.autoresizingMask = [.width]; view.isVerticallyResizable = true; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; scroll.hasVerticalScroller = true; return scroll
    }
    @objc func openSource() {
        guard let task, let selected, selected.sources.indices.contains(sources.indexOfSelectedItem) else { return }
        do {
            let source = selected.sources[sources.indexOfSelectedItem], files = try AgentFiles(workspace: task.workspace)
            guard !AgentFiles.sensitive(source.path), try AgentProjectIndex(workspace: task.workspace, storage: store.directory).contains(source.path) else { throw PetError("源码不在当前项目索引中") }
            let current = try files.fileHash(files.resolve(source.path), maximum: 512_000) == source.sha256
            let text = try files.read(source.path, offset: max(1, source.line - 3), limit: min(200, source.endLine - source.line + 10))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = (current ? "" : "来源已变化 · ") + source.path + ":\(source.line)"; window.appearance = NSAppearance(named: .aqua); window.center()
            let scroll = textPreview(text); (scroll.documentView as? NSTextView)?.font = .monospacedSystemFont(ofSize: 12, weight: .regular); window.contentView = scroll
            sourceWindow?.close(); sourceWindow = NSWindowController(window: window); sourceWindow?.showWindow(nil); window.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
    }
}
