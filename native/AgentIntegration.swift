import AppKit

@MainActor extension AppDelegate {
    func ensureAgent() {
        guard agentStore == nil else { return }
        let extensionHome = usesSideTaskCheck ? checkDirectory!.appendingPathComponent("shared-home") : checkDirectory != nil && ["--conversation-workspace-check", "--browser-check", "--browser-workspace-check", "--video-workspace-check", "--worktree-workspace-check", "--artifact-workspace-check", "--task-workspace-check", "--git-workspace-check", "--git-remote-page-check", "--name-editor-check", "--unsaved-changes-check", "--operation-confirmation-check", "--wiki-lifecycle-check", "--wiki-lifecycle-fixtures", "--wiki-lifecycle-reopen", "--knowledge-review-check", "--knowledge-review-fixtures", "--knowledge-review-reopen", "--knowledge-page-check", "--automation-page-check", "--attention-page-check", "--task-monitor-check", "--general-settings-check", "--settings-layout-check", "--appearance-check", "--settings-pages-check", "--mcp-input-check", "--task-find-check", "--appshot-external-ui", "--appshot-check", "--shortcut-check", "--conversation-creation-live-check", "--conversation-creation-preflight-check", "--automation-draft-check", "--agent-draft-check", "--plugin-team-check", "--plugin-scope-crash-check", "--plugin-scope-recovery-check", "--plugin-scope-check", "--plugin-update-check", "--plugin-update-crash-check", "--plugin-update-recovery-check", "--instruction-check", "--plugin-agent-live-check", "--rules-glob-retry-check", "--rules-glob-live-check", "--rules-live-check", "--local-rule-check", "--plugin-rule-check", "--plugin-hook-check", "--plugin-agent-check", "--file-open-check", "--attachment-drop-check", "--manual-ui", "--attention-live-ui", "--extension-check", "--hook-check", "--hook-service-check", "--hook-async-check", "--custom-agent-check", "--workbench-check", "--automation-check", "--task-model-check", "--mcp-content-check", "--worktree-check", "--worktree-creation-check", "--retention-check", "--file-change-check", "--desktop-check", "--canvas-check", "--organization-check", "--import-check", "--terminal-check", "--knowledge-check", "--knowledge-cards-check", "--markdown-check", "--markdown-edit-check", "--file-conflict-check", "--text-encoding-check", "--markdown-table-check", "--wiki-tree-check", "--wiki-plan-check", "--video-preview-check"].contains(where: CommandLine.arguments.contains) ? checkDirectory!.appendingPathComponent("shared-home") : FileManager.default.homeDirectoryForCurrentUser
        let mcpKeychain = checkDirectory.map { PetKeychain(service: "com.xjs.bluefatfish.mcp.check." + AgentFiles.hash(Data($0.path.utf8))) }
        let hookKeychain = checkDirectory.map { PetKeychain(service: "com.xjs.bluefatfish.hooks.check." + AgentFiles.hash(Data($0.path.utf8))) }
        let tasks = AgentStore(directory: store.directory, legacy: store.messages, extensionHome: extensionHome, mcpKeychain: mcpKeychain, hookKeychain: hookKeychain)
        let keychain = checkDirectory != nil && CommandLine.arguments.contains("--live-agent") ? PetKeychain(service: "com.xjs.bluefatfish.credentials") : store.keychain
        let runtime = AgentRuntime(store: tasks, keychain: keychain) { [weak self] in self?.store.preferences ?? PetPreferences() }
        runtime.taskSettings = { [weak self] in self?.generalSettings.settings ?? .init() }
        if checkDirectory != nil && ["--conversation-workspace-check", "--browser-workspace-check", "--video-workspace-check", "--worktree-workspace-check", "--artifact-workspace-check", "--task-workspace-check", "--git-workspace-check", "--git-remote-page-check", "--name-editor-check", "--unsaved-changes-check", "--operation-confirmation-check", "--wiki-lifecycle-check", "--wiki-lifecycle-fixtures", "--wiki-lifecycle-reopen", "--knowledge-review-check", "--knowledge-review-fixtures", "--knowledge-review-reopen", "--knowledge-page-check", "--automation-page-check", "--attention-page-check", "--task-monitor-check", "--general-settings-check", "--settings-layout-check", "--appearance-check", "--settings-pages-check", "--mcp-input-check", "--task-find-check", "--appshot-external-ui", "--appshot-check", "--shortcut-check", "--conversation-creation-live-check", "--conversation-creation-preflight-check"].contains(where: CommandLine.arguments.contains) { runtime.modelRequestCheck = { throw PetError("会话创建验收尚未核对本轮授权") } }
        agentStore = tasks; agentRuntime = runtime
        questionAutoSkip = AgentQuestionAutoSkip(runtime: runtime, enabled: { [weak self] in self?.closing == false && self?.generalSettings.error == nil && self?.generalSettings.settings.questionAutoSkip == true }, focused: { [weak self] id in
            NSApp.isActive && (self?.taskControls.contains(where: { $0.questionFocused(id) }) == true || NSApp.windows.contains { ($0.windowController as? AgentAttentionWindow)?.questionFocused(id) == true })
        }, interaction: { [weak self] event in
            Array(Set((self?.taskControls.compactMap { $0.questionInteraction(event) } ?? []) + NSApp.windows.compactMap { ($0.windowController as? AgentAttentionWindow)?.questionInteraction(event) }))
        })
        if tasks.deletions.pendingCount > 0 {
            Task { @MainActor [weak self] in
                let issue = await tasks.deletions.cleanup()
                if let issue { self?.inputControl.setStatus(issue, error: true) }; self?.refreshTaskWindows()
            }
        }
        tasks.knowledgeCards.runtime = runtime
        tasks.wikiMaintenance.runtime = runtime
        tasks.onChange = { [weak self] in self?.refreshTaskWindows() }
        tasks.sideTasks.onChange = { [weak self] in self?.refreshTaskWindows() }
        tasks.sideTasks.beforeDiscard = { [weak self] ids in try self?.requireTaskDeletionAllowed(ids) }
        tasks.sideTasks.startSession()
        tasks.attention.onChange = { [weak self] in self?.taskControls.forEach { $0.refreshAttention() } }
        tasks.organization.onChange = { [weak self] in self?.refreshTaskWindows() }
        tasks.wikiMaintenance.onChange = { [weak self] _ in self?.refreshTaskWindows() }
        tasks.knowledgeCards.onChange = { [weak self] root in for window in self?.taskControls ?? [] { window.refreshKnowledgeCards(workspace: root) } }
        tasks.dataImport.onChange = { [weak self] in for window in self?.taskControls ?? [] { window.refreshDataImport() }; self?.refreshTaskWindows() }
        automationNotifications.taskRecord = { [weak tasks] id in tasks?.task(id) }
        _ = tasks.mcp.observeContent { [weak self, weak tasks] in
            guard let tasks else { return }
            self?.refreshTaskWindows()
            for request in tasks.mcp.userInputs.requests {
                if let task = tasks.task(request.taskID) { self?.automationNotifications.question(task, requestID: request.id, isCurrent: { [weak tasks] in tasks?.mcp.userInputs.requests.contains { $0.id == request.id } == true && tasks?.task(request.taskID)?.archived == false }) }
            }
        }
        tasks.browser.onChange = { [weak self] id in
            for window in self?.taskControls ?? [] where window.agentTaskID == id { window.scheduleRender() }
        }
        tasks.browser.onDraftCapture = { [weak self] id, shot, marks, note in
            guard let self else { throw PetError("任务窗口已关闭") }
            try await self.taskControl(for: id).attachBrowserCapture(shot, marks: marks, note: note, taskID: id)
        }
        tasks.browser.onPresent = { [weak self] browser in
            guard let self else { throw PetError("任务窗口已关闭") }
            let owner = self.taskControls.first(where: { $0.window === browser.settingsHostWindow }) ?? self.taskControl(for: browser.taskID)
            try owner.presentBrowserWorkspace(browser)
        }
        tasks.browser.onDetach = { [weak self] browser in
            guard let owner = self?.taskControls.first(where: { $0.window === browser.settingsHostWindow }) else { throw PetError("所属任务窗口已关闭") }
            try owner.detachBrowserWorkspace(browser)
        }
        runtime.onChange = { [weak self] id in
            guard let self else { return }
            if !closing, let task = tasks.task(id) { automationNotifications.pending(task) }
            self.refreshTaskWindows(); self.refreshVoiceBusy()
            self.questionAutoSkip?.refresh()
            if let task = tasks.task(id), task.kind == AgentKnowledgeCards.kind, task.status != .running, let root = task.workspace { self.taskControls.forEach { $0.refreshKnowledgeCards(workspace: root) } }
            if let task = tasks.task(id), task.kind == "wiki", [.failed, .stopped].contains(task.status), let root = task.workspace { tasks.wikiMaintenance.changed(workspace: root) }
            self.refreshAgentAnimation()
            if !self.selectedAgentBusy { self.startPendingVoiceListen() }
        }
        tasks.projectChanges.onChange = { [weak runtime] id in runtime?.onChange?(id) }
        tasks.canvases.onChange = { [weak runtime] id in runtime?.onChange?(id) }
        tasks.offices.onPresent = { [weak self] editor, location in
            guard let self else { throw PetError("任务窗口已关闭") }
            let owner = self.taskControls.first(where: { $0.window === editor.settingsHostWindow }) ?? self.taskControl(for: editor.taskID)
            if location == .window { try owner.presentArtifactWindow(editor, taskID: editor.taskID) }
            else { try owner.presentOfficeWorkspace(editor) }
        }
        tasks.canvases.onPresent = { [weak self] editor, id, location in
            guard let self else { throw PetError("任务窗口已关闭") }
            let owner = self.taskControls.first(where: { $0.window === editor.settingsHostWindow }) ?? self.taskControl(for: editor.taskID)
            if location == .window { try owner.presentArtifactWindow(editor, taskID: editor.taskID) }
            else { try owner.presentCanvasWorkspace(editor, id: id) }
        }
        tasks.canvases.onDraftCapture = { [weak self] id, shot, marks, note in
            guard let self else { throw PetError("任务窗口已关闭") }; try await self.taskControl(for: id).attachCanvasCapture(shot, marks: marks, note: note, taskID: id)
        }
        runtime.onComplete = { [weak self] id, text in
            guard let self else { return }
            if tasks.task(id)?.isProjectDocumentation == true {
                let messageID = tasks.task(id)?.messages.last?.id
                Task { [weak self] in
                    do {
                        if tasks.task(id)?.kind == AgentKnowledgeCards.kind { try await tasks.knowledgeCards.complete(id) }
                        else { try await AgentWiki.finalize(store: tasks, taskID: id); if let language = tasks.task(id)?.wikiJob?.language { await tasks.wikiMaintenance.published(taskID: id, language: language, expectedID: id) } }
                    }
                    catch {
                        if tasks.task(id)?.status == .completed, tasks.task(id)?.messages.last?.id == messageID {
                            tasks.update(id) { $0.status = .failed; $0.goalAccepted = nil; $0.events.append(AgentEvent(kind: $0.kind ?? "wiki", title: "项目知识校验未完成", detail: error.localizedDescription, status: "failed")) }
                            if let root = tasks.task(id)?.workspace { tasks.knowledgeCards.notices[root] = error.localizedDescription }
                        }
                    }
                    if let root = tasks.task(id)?.workspace { self?.taskControls.forEach { $0.refreshKnowledgeCards(workspace: root) }; tasks.knowledgeCards.changed(workspace: root) }
                    self?.refreshTaskWindows(); self?.refreshAgentAnimation(); self?.refreshVoiceBusy()
                    if tasks.task(id)?.status == .completed { self?.completeAgentResponse(id: id, text: text) }
                }
            } else { self.completeAgentResponse(id: id, text: text) }
        }
        tasks.automations.onNotice = { [weak self] run in
            guard let self, !self.closing else { return }; self.taskControls.forEach { $0.refreshAutomationBadge() }
            if self.checkDirectory == nil, tasks.attention.settings.automationNotifications { self.automationNotifications.post(run) }
        }
        automationNotifications.onOpen = { [weak self] id in guard let self, tasks.task(id) != nil else { return }; let window = self.taskControl(for: id); window.showAgentTask(id); window.show(tab: "chat") }
        tasks.worktreeRetention.onChange = { [weak self] in for window in self?.taskControls ?? [] { window.refreshWorktreeRetention() } }
        if checkDirectory == nil { tasks.automations.start(store: tasks, runtime: runtime); tasks.worktreeRetention.start(store: tasks); tasks.knowledgeCards.resume(); tasks.wikiMaintenance.resume() }
        tasks.attention.refresh()
        questionAutoSkip?.refresh()
    }
    private func completeAgentResponse(id: String, text: String) {
        if !closing, let task = agentStore?.task(id) { automationNotifications.completed(task) }
        guard agentStore?.selectedID == id, agentStore?.task(id)?.automation == nil, !text.isEmpty else { return }
        showBubble(String(text.prefix(320)))
        if store.preferences.voiceEnabled { synthesize(text, preferences: store.preferences) }
    }
    func refreshAgentAnimation() {
        let status = agentStore?.selected?.status
        let next = status == .running ? "thinking" : status == .waiting ? "observing" : "idle"
        if agentAnimationPhase != next { agentAnimationPhase = next; emit("screenState", ["phase": next, "direction": 0.4]) }
    }
    func recordCompanionComment(_ text: String) {
        guard let tasks = agentStore else { return }
        let id: String
        if let existing = tasks.tasks.first(where: { $0.kind == "companion" && !$0.archived && ![.running, .waiting].contains($0.status) }) { id = existing.id }
        else {
            let selected = tasks.selectedID
            id = tasks.create(title: "小鲸的陪伴", mode: .ask)
            tasks.update(id) { $0.kind = "companion" }; tasks.selectedID = selected
        }
        tasks.update(id) { $0.messages.append(AgentMessage(role: "assistant", content: text)) }
    }
}
