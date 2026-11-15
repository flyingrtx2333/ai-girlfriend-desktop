import AppKit

// One serialized writer per task window. Cold tabs keep their stored page until
// materialized; closing a tab and quitting the app have different lifecycles.
@MainActor final class AgentWorkspaceSession {
    private weak var owner: ControlWindow?
    private let journal: AgentWorkspaceRecovery
    let id: String
    private var layoutHash: String?, previous: AgentWorkspaceRecovery.Window?
    private var pages: [String: AgentWorkspaceRecovery.Page] = [:], pageHashes: [String: String] = [:]
    private var revision = 0, savedRevision = -1, disabled = false, stopped = false, closing = false
    private var job: Task<Void, Never>?, roots: [String: Task<Void, Never>] = [:]
    private var tabStateJob: Task<Void, Never>?
    private var failure: Error?
    private(set) var preservedEditors = Set<ObjectIdentifier>()
    var isCurrent: Bool { disabled || stopped || (savedRevision == revision && roots.isEmpty && tabStateJob == nil) }

    init(owner: ControlWindow, profile: URL, saved: AgentWorkspaceRecovery.Saved<AgentWorkspaceRecovery.Window>?) {
        self.owner = owner; journal = AgentWorkspaceRecovery(profile: profile)
        id = saved?.value.id ?? UUID().uuidString; layoutHash = saved?.hash; previous = saved?.value
        owner.taskWorkspace.onRecoveryChange = { [weak self] in self?.changed() }
        owner.taskWorkspace.onRestoreRoot = { [weak self] task, tab in self?.restore(task: task, tab: tab) }
        do { if let saved { try owner.taskWorkspace.restoreLayouts(saved.value.tasks); loadTabStates(saved.value.tasks) } }
        catch { disabled = true; owner.setStatus(error.localizedDescription, error: true) }
    }
    private func loadTabStates(_ tasks: [AgentWorkspaceRecovery.TaskLayout]) {
        let journal = journal, windowID = id
        tabStateJob = Task { @MainActor [weak self] in
            guard let self else { return }; defer { tabStateJob = nil }
            let result = await Task.detached(priority: .utility) {
                var values: [String: Bool] = [:], issues: [String] = []
                for task in tasks { for tab in task.tabs {
                    do { values[tab.id] = try journal.loadTabDirtyState(windowID: windowID, pageID: tab.id, taskID: task.taskID) }
                    catch { issues.append(tab.title + "：" + error.localizedDescription) }
                } }
                return (values, issues)
            }.value
            guard !stopped, !Task.isCancelled, let owner else { return }
            owner.taskWorkspace.applyRecoveredTabStates(result.0)
            if !result.1.isEmpty { owner.setStatus("部分标签状态未读取，原记录已保留：" + result.1.prefix(2).joined(separator: "；"), error: true) }
        }
    }
    func changed() {
        guard !stopped, !disabled else { return }; revision &+= 1
        guard job == nil, !closing else { return }
        job = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }; await savePending(); job = nil
        }
    }
    private func savePending() async {
        guard !stopped, !disabled, let owner else { return }
        if let tabStateJob { await tabStateJob.value }
        do {
            while savedRevision != revision {
                // A restore owns its page until its factory has finished. Do
                // not replace it with the fresh editor's initial disk content.
                let pending = Array(roots.values); for root in pending { await root.value }
                let targetRevision = revision
                for (_, tab, controller) in owner.taskWorkspace.recoveryEditors {
                    if let record = controller as? AgentRecordWindow {
                        let page = try record.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    } else if let office = controller as? AgentOfficeWindow {
                        try await office.persistWorkspaceRecovery(previous: pages[tab.id]) { page, asset in
                            try await self.persist(page, asset: asset, pageID: tab.id)
                        }
                    } else if let canvas = controller as? AgentCanvasWindow {
                        let page = try canvas.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    } else if let mcp = controller as? AgentMCPContentWindow {
                        let page = try mcp.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    } else if let editor = controller as? AgentEditResendWindow {
                        let page = try editor.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    }
                }
                let journal = journal
                var layout = AgentWorkspaceRecovery.Window(id: id, number: owner.taskWindowNumber, taskID: owner.agentTaskID,
                    frame: owner.window.map { .init(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }, tasks: owner.taskWorkspace.recoveryLayouts)
                layout.floating = previous?.floating ?? []
                let expected = layoutHash, capturedLayout = layout
                let saved = try await Task.detached(priority: .utility) { try journal.saveWindow(capturedLayout, expected: expected) }.value
                layoutHash = saved.hash; previous = saved.value; savedRevision = targetRevision; failure = nil
                preservedEditors = Set(owner.taskWorkspace.recoveryEditors.compactMap { _, _, controller in
                    if let record = controller as? AgentRecordWindow, record.canPreserveForQuit { return ObjectIdentifier(record) }
                    if let office = controller as? AgentOfficeWindow, office.canPreserveForQuit { return ObjectIdentifier(office) }
                    if let canvas = controller as? AgentCanvasWindow, canvas.canPreserveForQuit { return ObjectIdentifier(canvas) }
                    if let mcp = controller as? AgentMCPContentWindow, mcp.canPreserveForQuit { return ObjectIdentifier(mcp) }
                    if let editor = controller as? AgentEditResendWindow, editor.canPreserveForQuit { return ObjectIdentifier(editor) }
                    return nil
                })
            }
        } catch { failure = error; preservedEditors = []; owner.setStatus("工作区恢复未保存：" + error.localizedDescription, error: true) }
    }
    private func persist(_ page: AgentWorkspaceRecovery.Page, asset: URL?, pageID: String) async throws {
        let journal = journal, windowID = id, hash = pageHashes[pageID]
        let saved = try await Task.detached(priority: .utility) { try journal.savePage(page, asset: asset, windowID: windowID, pageID: pageID, expected: hash) }.value
        // Keep each successful revision if a later page or layout fails.
        pageHashes[pageID] = saved.hash; pages[pageID] = saved.value
        owner?.taskWorkspace.applyRecoveredTabStates([pageID: saved.value.dirty])
    }
    func flush() async throws {
        guard !disabled else { return }
        if let tabStateJob { await tabStateJob.value }
        if let job { await job.value }
        if savedRevision != revision { await savePending() }
        if let failure { throw failure }
    }
    func stop() { stopped = true; tabStateJob?.cancel(); tabStateJob = nil; preservedEditors = [] }
    func markClosed() async throws {
        guard !disabled else { stop(); return }
        try await flush()
        guard var layout = previous else { stop(); return }
        let closingRevision = revision; closing = true
        defer { closing = false; if !stopped, revision != closingRevision { changed() } }
        layout.closed = true
        let journal = journal, expected = layoutHash
        let saved = try await Task.detached(priority: .utility) { try journal.saveWindow(layout, expected: expected) }.value
        layoutHash = saved.hash; previous = saved.value
        guard revision == closingRevision else { throw PetError("关闭期间内容已变化，请重新检查后关闭") }
        stop()
    }
    private func restore(task: String, tab: AgentWorkspaceRecovery.Tab) {
        guard !stopped, !disabled, roots[tab.id] == nil else { return }
        roots[tab.id] = Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            defer { roots[tab.id] = nil; owner.taskWorkspace.retryRecovery(tab.id) }
            do {
                let journal = journal, windowID = id
                let loaded = try await Task.detached(priority: .utility) { try journal.loadPage(windowID: windowID, pageID: tab.id, taskID: task) }.value
                guard !stopped, owner.agentTaskID == task, owner.taskWorkspace.recoveryLayouts.contains(where: { $0.taskID == task && $0.tabs.contains(where: { $0.id == tab.id }) }) else { return }
                if let loaded { pageHashes[tab.id] = loaded.saved.hash; pages[tab.id] = loaded.saved.value }
                try await owner.materializeRecoveryRoot(task: task, tab: tab, loaded: loaded)
                changed()
            } catch { owner.setStatus("标签恢复失败，原草稿已保留：" + error.localizedDescription, error: true) }
        }
    }
}

@MainActor extension AppDelegate {
    func flushWorkspaceWindows() async -> Bool {
        repeat {
            for window in taskControls { if !(await window.flushWorkspaceRecovery()) { return false } }
        } while taskControls.contains { $0.workspaceSession?.isCurrent == false }
        return true
    }
    var workspaceRecoveryEnabled: Bool { checkDirectory == nil || CommandLine.arguments.contains("--workspace-edit-recovery-check") || CommandLine.arguments.contains("--workspace-edit-recovery-ui") || CommandLine.arguments.contains("--workspace-mcp-recovery-check") || CommandLine.arguments.contains("--workspace-mcp-recovery-ui") || CommandLine.arguments.contains("--workspace-canvas-recovery-check") || CommandLine.arguments.contains("--workspace-canvas-recovery-ui") || CommandLine.arguments.contains("--workspace-office-recovery-check") || CommandLine.arguments.contains("--workspace-office-recovery-ui") || CommandLine.arguments.contains("--workspace-recovery-lifecycle-check") || CommandLine.arguments.contains("--workspace-recovery-ui") }
    func loadWorkspaceWindows() {
        guard workspaceRecoveryEnabled else { return }
        do {
            let listing = try AgentWorkspaceRecovery(profile: store.directory).list()
            workspaceRecoveryWindows = listing.windows.filter { !$0.value.closed }.sorted { $0.value.number == $1.value.number ? $0.value.id < $1.value.id : $0.value.number < $1.value.number }
            workspaceRecoveryIssues = listing.issues
        } catch { workspaceRecoveryIssues = [error.localizedDescription] }
    }
    func restoreAdditionalWorkspaceWindows() {
        guard workspaceRecoveryEnabled, !workspaceRecoveryStarted else { return }; workspaceRecoveryStarted = true
        var numbers: Set<Int> = [1]
        for saved in workspaceRecoveryWindows where saved.value.number != 1 {
            guard saved.value.number < Int.max, numbers.insert(saved.value.number).inserted, let id = saved.value.taskID, let task = agentStore?.task(id), task.sideTask?.retained != false else { workspaceRecoveryIssues.append("部分任务窗口已不可用，原记录已保留"); continue }
            let child = ControlWindow(companion: self, taskID: id, windowNumber: saved.value.number, recovery: saved)
            additionalTaskWindows.append(child); nextTaskWindowNumber = max(nextTaskWindowNumber, saved.value.number + 1)
            child.showAgentTask(id); child.show(tab: "chat")
        }
        if !workspaceRecoveryIssues.isEmpty { control.setStatus("部分工作区未恢复：" + workspaceRecoveryIssues.prefix(2).joined(separator: "；"), error: true) }
    }
}
