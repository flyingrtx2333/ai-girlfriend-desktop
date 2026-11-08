import AppKit

@MainActor extension AppDelegate {
    func ensureAgent() {
        guard agentStore == nil else { return }
        let extensionHome = checkDirectory != nil && ["--extension-check", "--hook-check", "--hook-service-check", "--hook-async-check", "--custom-agent-check", "--workbench-check", "--automation-check", "--task-model-check", "--mcp-content-check", "--worktree-check", "--worktree-creation-check", "--retention-check", "--file-change-check", "--desktop-check", "--canvas-check", "--organization-check", "--import-check", "--terminal-check"].contains(where: CommandLine.arguments.contains) ? checkDirectory!.appendingPathComponent("shared-home") : FileManager.default.homeDirectoryForCurrentUser
        let mcpKeychain = checkDirectory.map { PetKeychain(service: "com.xjs.bluefatfish.mcp.check." + AgentFiles.hash(Data($0.path.utf8))) }
        let hookKeychain = checkDirectory.map { PetKeychain(service: "com.xjs.bluefatfish.hooks.check." + AgentFiles.hash(Data($0.path.utf8))) }
        let tasks = AgentStore(directory: store.directory, legacy: store.messages, extensionHome: extensionHome, mcpKeychain: mcpKeychain, hookKeychain: hookKeychain)
        let keychain = checkDirectory != nil && CommandLine.arguments.contains("--live-agent") ? PetKeychain(service: "com.xjs.bluefatfish.credentials") : store.keychain
        let runtime = AgentRuntime(store: tasks, keychain: keychain) { [weak self] in self?.store.preferences ?? PetPreferences() }
        agentStore = tasks; agentRuntime = runtime
        tasks.dataImport.onChange = { [weak self] in self?.control.refreshDataImport(); self?.control.scheduleRender() }
        _ = tasks.mcp.observeContent { [weak self] in self?.control.scheduleRender() }
        tasks.browser.onDraftCapture = { [weak self] id, shot, marks, note in
            guard let self else { throw PetError("任务窗口已关闭") }
            try await self.control.attachBrowserCapture(shot, marks: marks, note: note, taskID: id)
        }
        runtime.onChange = { [weak self] id in
            guard let self else { return }
            self.control.scheduleRender(); self.control.refreshAutomationBadge(); self.refreshVoiceBusy()
            self.refreshAgentAnimation()
            if !self.selectedAgentBusy { self.startPendingVoiceListen() }
        }
        tasks.projectChanges.onChange = { [weak runtime] id in runtime?.onChange?(id) }
        tasks.canvases.onChange = { [weak runtime] id in runtime?.onChange?(id) }
        tasks.canvases.onDraftCapture = { [weak self] id, shot, marks, note in
            guard let self else { throw PetError("任务窗口已关闭") }; try await self.control.attachCanvasCapture(shot, marks: marks, note: note, taskID: id)
        }
        runtime.onComplete = { [weak self] id, text in
            guard let self else { return }
            if tasks.task(id)?.kind == "wiki" {
                let messageID = tasks.task(id)?.messages.last?.id
                Task { [weak self] in
                    do { try await AgentWiki.finalize(store: tasks, taskID: id) }
                    catch {
                        if tasks.task(id)?.status == .completed, tasks.task(id)?.messages.last?.id == messageID { tasks.update(id) { $0.status = .failed; $0.goalAccepted = nil; $0.events.append(AgentEvent(kind: "wiki", title: "Wiki 校验未通过", detail: error.localizedDescription, status: "failed")) } }
                    }
                    self?.control.scheduleRender(); self?.refreshAgentAnimation(); self?.refreshVoiceBusy()
                    if tasks.task(id)?.status == .completed { self?.completeAgentResponse(id: id, text: text) }
                }
            } else { self.completeAgentResponse(id: id, text: text) }
        }
        tasks.automations.onNotice = { [weak self] run in
            guard let self, !self.closing else { return }; self.control.refreshAutomationBadge()
            if self.checkDirectory == nil { self.automationNotifications.post(run) }
        }
        automationNotifications.onOpen = { [weak self] id in self?.control.show(tab: "chat"); self?.control.showAgentTask(id) }
        tasks.worktreeRetention.onChange = { [weak self] in self?.control.refreshWorktreeRetention() }
        if checkDirectory == nil { tasks.automations.start(store: tasks, runtime: runtime); tasks.worktreeRetention.start(store: tasks) }
    }
    private func completeAgentResponse(id: String, text: String) {
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
