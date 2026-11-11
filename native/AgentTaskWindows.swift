import AppKit

@MainActor final class AgentWindowDraft {
    let id: String, storage: NSTextStorage
    let undo = UndoManager()
    var saved: String
    var pendingSave = false
    init(id: String, value: String, attributes: [NSAttributedString.Key: Any]) {
        self.id = id; saved = value; storage = NSTextStorage(string: value, attributes: attributes)
    }
    func refresh(_ value: String, attributes: [NSAttributedString.Key: Any]) {
        guard !pendingSave, value != saved else { return }
        guard storage.string == saved || storage.string == value else { return }
        if storage.string != value { storage.setAttributedString(NSAttributedString(string: value, attributes: attributes)); undo.removeAllActions() }
        saved = value
    }
}

@MainActor extension AppDelegate {
    var taskControls: [ControlWindow] { [control] + additionalTaskWindows }
    var inputControl: ControlWindow { focusedTaskControl ?? control }
    func taskControl(for id: String) -> ControlWindow {
        if inputControl.agentTaskID == id { return inputControl }
        return taskControls.first(where: { $0.agentTaskID == id && $0.window?.isVisible == true }) ?? inputControl
    }
    func windowDraft(_ id: String, attributes: [NSAttributedString.Key: Any]) -> AgentWindowDraft? {
        guard let task = agentStore?.task(id) else { return nil }
        if let value = taskWindowDrafts.object(forKey: id as NSString) { value.refresh(task.draft ?? "", attributes: attributes); return value }
        let value = AgentWindowDraft(id: id, value: task.draft ?? "", attributes: attributes)
        taskWindowDrafts.setObject(value, forKey: id as NSString); return value
    }
    func refreshTaskWindows() { agentStore?.attention.refresh(); for window in taskControls { window.scheduleRender(); window.refreshAutomationBadge(); window.refreshAttention() } }
    func showAttention(settings: Bool = false) {
        if settings { inputControl.showAttentionPreferences(); return }
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { return }
        if attentionWindow == nil {
            let window = AgentAttentionWindow(attention: tasks.attention, runtime: runtime)
            window.onOpenTask = { [weak self] id in guard let self else { return }; let owner = self.taskControl(for: id); owner.showAgentTask(id); owner.show(tab: "chat") }
            window.onOpenSettings = { [weak self] in self?.inputControl.showAttentionPreferences() }
            attentionWindow = window
        }
        attentionWindow?.showWindow(nil); attentionWindow?.window?.makeKeyAndOrderFront(nil); tasks.attention.refresh(); attentionWindow?.refresh()
        if settings { attentionWindow?.showSettings() }
    }
    func persistTaskDrafts(_ id: String? = nil) -> Bool {
        var saved = true
        for window in taskControls where id == nil || window.agentTaskID == id { if !window.saveWindowDraft() { saved = false } }
        return saved
    }
    func openTaskWindow(_ id: String, from owner: ControlWindow) {
        guard agentStore?.task(id) != nil, owner.saveWindowDraft(), persistTaskDrafts(id) else { return }
        do { if agentStore?.task(id)?.sideTask != nil { try agentStore?.sideTasks.open(id) } }
        catch { owner.setStatus(error.localizedDescription, error: true); return }
        let window = ControlWindow(companion: self, taskID: id, windowNumber: nextTaskWindowNumber)
        if agentStore?.task(id)?.sideTask != nil { window.sideTaskTabID = id }
        window.window?.tabbingMode = .disallowed
        nextTaskWindowNumber += 1; additionalTaskWindows.append(window)
        window.window?.cascadeTopLeft(from: owner.window.map { NSPoint(x: $0.frame.minX + 26, y: $0.frame.maxY - 26) } ?? NSPoint(x: 90, y: 850))
        if let view = window.window { view.setFrame(view.constrainFrameRect(view.frame, to: owner.window?.screen), display: false) }
        window.showAgentTask(id); window.show(tab: "chat")
    }
    func showTaskInMainWindow(_ id: String) {
        guard agentStore?.task(id) != nil else { return }; control.showAgentTask(id); control.show(tab: "chat")
        if let window = control.window { window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil) }
    }
    func openSideTask(_ id: String, from owner: ControlWindow) {
        guard let tasks = agentStore, owner.saveWindowDraft(), persistTaskDrafts(id) else { return }
        do {
            try tasks.sideTasks.open(id)
            if let existing = taskControls.first(where: { $0.sideTaskTabID == id }) {
                existing.show(tab: "chat"); if let window = existing.window { window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil) }; return
            }
            let anchor = owner.sideTaskTabID == nil ? owner : control
            if let parent = tasks.task(id)?.sideTask?.parentID, tasks.tasks.contains(where: { $0.id == parent }) { anchor.showAgentTask(parent) }
            let child = ControlWindow(companion: self, taskID: id, windowNumber: nextTaskWindowNumber); child.sideTaskTabID = id
            nextTaskWindowNumber += 1; additionalTaskWindows.append(child)
            if let host = anchor.window, let window = child.window {
                host.tabbingIdentifier = "BlueFatFishTasks"; window.tabbingIdentifier = host.tabbingIdentifier
                host.tabbingMode = .preferred; window.tabbingMode = .preferred; host.addTabbedWindow(window, ordered: .above)
            }
            child.showAgentTask(id); child.show(tab: "chat")
        } catch { owner.setStatus(error.localizedDescription, error: true) }
    }
    func removeTaskWindow(_ window: ControlWindow) {
        additionalTaskWindows.removeAll { $0 === window }
        if focusedTaskControl === window { focusedTaskControl = nil }
    }
    func requireTaskDeletionAllowed(_ ids: Set<String>) throws {
        try attentionWindow?.requireDeletionAllowed(ids)
        for window in taskControls { try window.requireTaskDeletionAllowed(ids) }
    }
    func closeDeletedTaskWindows(_ ids: Set<String>) {
        for window in taskControls { window.closeDeletedTaskRecords(ids); window.scheduleRender() }
    }
}
