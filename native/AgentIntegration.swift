import AppKit

@MainActor extension AppDelegate {
    func ensureAgent() {
        guard agentStore == nil else { return }
        let tasks = AgentStore(directory: store.directory, legacy: store.messages)
        let keychain = checkDirectory != nil && CommandLine.arguments.contains("--live-agent") ? PetKeychain(service: "com.xjs.bluefatfish.credentials") : store.keychain
        let runtime = AgentRuntime(store: tasks, keychain: keychain) { [weak self] in self?.store.preferences ?? PetPreferences() }
        agentStore = tasks; agentRuntime = runtime
        runtime.onChange = { [weak self] id in
            guard let self else { return }
            self.control.scheduleRender(); self.refreshVoiceBusy()
            if tasks.selectedID == id {
                let phase = tasks.task(id)?.status
                let next = phase == .running ? "thinking" : phase == .waiting ? "observing" : "idle"
                if self.agentAnimationPhase != next { self.agentAnimationPhase = next; self.emit("screenState", ["phase": next, "direction": 0.4]) }
            }
            if !self.selectedAgentBusy { self.startPendingVoiceListen() }
        }
        runtime.onComplete = { [weak self] id, text in
            guard let self, tasks.selectedID == id, !text.isEmpty else { return }
            self.showBubble(String(text.prefix(320)))
            if self.store.preferences.voiceEnabled { self.synthesize(text, preferences: self.store.preferences) }
        }
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
