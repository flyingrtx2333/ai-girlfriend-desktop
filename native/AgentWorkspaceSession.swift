import AppKit

extension AgentWorkspaceRecovery.Frame {
    @MainActor init(_ window: NSWindow) { self.init(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height) }
    @MainActor func apply(to window: NSWindow?) {
        guard valid, let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(visible.width, max(window.minSize.width, self.width)), height = min(visible.height, max(window.minSize.height, self.height))
        window.setFrame(NSRect(x: max(visible.minX, min(x, visible.maxX - width)), y: max(visible.minY, min(y, visible.maxY - height)), width: width, height: height), display: false)
    }
}

// The journal uses a nonblocking file lock to reject external writers. Keep
// this window's own reads and writes serialized so eager restores cannot race it.
private actor AgentWorkspaceJournal {
    private let storage: AgentWorkspaceRecovery
    init(profile: URL) { storage = AgentWorkspaceRecovery(profile: profile) }
    func tabStates(_ tasks: [AgentWorkspaceRecovery.TaskLayout], windowID: String) -> ([String: Bool], [String]) {
        var values: [String: Bool] = [:], issues: [String] = []
        for task in tasks { for tab in task.tabs {
            do { values[tab.id] = try storage.loadTabDirtyState(windowID: windowID, pageID: tab.id, taskID: task.taskID) }
            catch { issues.append(tab.title + "：" + error.localizedDescription) }
        } }
        return (values, issues)
    }
    func loadPage(windowID: String, pageID: String, taskID: String) throws -> AgentWorkspaceRecovery.LoadedPage? {
        try storage.loadPage(windowID: windowID, pageID: pageID, taskID: taskID)
    }
    func savePage(_ page: AgentWorkspaceRecovery.Page, asset: URL?, windowID: String, pageID: String, expected: String?) throws -> AgentWorkspaceRecovery.Saved<AgentWorkspaceRecovery.Page> {
        try storage.savePage(page, asset: asset, windowID: windowID, pageID: pageID, expected: expected)
    }
    func saveWindow(_ layout: AgentWorkspaceRecovery.Window, expected: String?, marketCopy: AgentWorkspaceRecovery.MarketReviewCopy? = nil) throws -> AgentWorkspaceRecovery.Saved<AgentWorkspaceRecovery.Window> {
        try storage.saveWindow(layout, expected: expected, marketCopy: marketCopy)
    }
    func loadMarketReviewCopy(windowID: String, hash: String) throws -> Data {
        try storage.loadMarketReviewCopy(windowID: windowID, hash: hash)
    }
    func saveTerminals(_ layout: AgentTerminalLayout, expected: String?) throws -> AgentWorkspaceRecovery.Saved<AgentTerminalLayout> {
        try storage.saveTerminalLayout(layout, expected: expected)
    }
    func saveTerminalAppearance(_ appearance: AgentTerminalAppearanceRecord, expected: String?) throws -> AgentWorkspaceRecovery.Saved<AgentTerminalAppearanceRecord> {
        try storage.saveTerminalAppearance(appearance, expected: expected)
    }
}

// One serialized journal per task window. Cold tabs keep their stored page until
// materialized; closing a tab and quitting the app have different lifecycles.
@MainActor final class AgentWorkspaceSession: NSObject {
    private weak var owner: ControlWindow?
    private let journal: AgentWorkspaceJournal
    let id: String
    private var layoutHash: String?, previous: AgentWorkspaceRecovery.Window?
    private var savedTerminals: AgentWorkspaceRecovery.Saved<AgentTerminalLayout>?
    private var terminalRecoveryReadOnly = false
    private var savedTerminalAppearance: AgentWorkspaceRecovery.Saved<AgentTerminalAppearanceRecord>?
    private var terminalAppearanceReadOnly = false
    private var pages: [String: AgentWorkspaceRecovery.Page] = [:], pageHashes: [String: String] = [:]
    private var revision = 0, savedRevision = -1, disabled = false, stopped = false, closing = false
    private var job: Task<Void, Never>?, roots: [String: Task<Void, Never>] = [:]
    private var tabStateJob: Task<Void, Never>?
    private var failure: Error?
    private var coldFloating: [AgentWorkspaceRecovery.FloatingPage] = []
    private var coldKnowledge: AgentWorkspaceRecovery.Knowledge?
    private var coldSettings: AgentSettingsRecovery.State?, settingsFailure: String?
    private var coldSettingsNavigation: AgentSettingsRecovery.Navigation?
    private var coldAutomation: AgentWorkspaceRecovery.Automation?, automationFailure: String?
    var pendingSettingsCategory: String? { coldSettings?.category }
    var hasPendingAutomation: Bool { coldAutomation != nil }
    private var knowledgeFailure: String?
    var hasPendingKnowledge: Bool { coldKnowledge != nil }
    private var floatingFailures: [String: String] = [:]
    private var floating: [String: (AgentWorkspaceRecovery.FloatingPage, AgentSettingsPageController)] = [:]
    private(set) var preservedEditors = Set<ObjectIdentifier>()
    func hasPreservedModelDraft(_ draft: AgentModelSettingsRecovery.Draft) -> Bool {
        guard !disabled, !stopped, let saved = previous?.settingsNavigation?.modelSettings?.draft else { return false }
        return saved.base == draft.base && saved.form == draft.form
    }
    var isCurrent: Bool { disabled || stopped || (savedRevision == revision && roots.isEmpty && tabStateJob == nil) }
    var floatingControllers: [AgentSettingsPageController] { floating.values.map(\.1) }
    var floatingRecoveryReadback: [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        return ["windowID": id, "coldRoots": coldFloating.map(\.tab.root), "errors": floatingFailures,
                "open": floating.map { ["pageID": $0.key, "root": $0.value.0.tab.root, "controller": String(describing: type(of: $0.value.1))] }]
    }
    private var editors: [(String, AgentWorkspaceRecovery.Tab, AgentSettingsPageController)] {
        (owner?.taskWorkspace.recoveryEditors ?? []) + floating.values.map { ($0.0.taskID, $0.0.tab, $0.1) }
    }

    init(owner: ControlWindow, profile: URL, saved: AgentWorkspaceRecovery.Saved<AgentWorkspaceRecovery.Window>?) {
        self.owner = owner; journal = AgentWorkspaceJournal(profile: profile)
        id = saved?.value.id ?? UUID().uuidString; layoutHash = saved?.hash; previous = saved?.value
        coldFloating = saved?.value.floating ?? []
        coldKnowledge = saved?.value.knowledge
        coldSettings = saved?.value.settings
        coldSettingsNavigation = saved?.value.settingsNavigation
        coldAutomation = saved?.value.automation
        super.init()
        owner.taskWorkspace.onRecoveryChange = { [weak self] in self?.changed() }
        owner.knowledgePageHost.onRecoveryChange = { [weak self] in self?.changed() }
        owner.onSettingsRecoveryChange = { [weak self] in self?.changed() }
        owner.taskWorkspace.onRestoreRoot = { [weak self] task, tab in self?.restore(task: task, tab: tab) }
        do { if let saved { try owner.taskWorkspace.restoreLayouts(saved.value.tasks); loadTabStates(saved.value.tasks) } }
        catch { disabled = true; owner.setStatus(error.localizedDescription, error: true) }
        if saved != nil, !disabled {
            do {
                let recovery = AgentWorkspaceRecovery(profile: profile)
                savedTerminals = try recovery.loadTerminalLayout(windowID: id)
                if let layout = savedTerminals?.value {
                    do { savedTerminalAppearance = try recovery.loadTerminalAppearance(windowID: id) }
                    catch {
                        terminalAppearanceReadOnly = true
                        owner.setStatus("终端外观未恢复，原记录已保留：" + error.localizedDescription, error: true)
                    }
                    let appearance = savedTerminalAppearance?.value.preference(forLegacyDark: layout.dark) ?? AgentTerminalAppearance(dark: layout.dark)
                    owner.restoreTerminalLayout(layout, appearance: appearance)
                }
            } catch {
                terminalRecoveryReadOnly = true
                owner.setStatus("终端记录未恢复，原记录已保留：" + error.localizedDescription, error: true)
            }
        }
        restoreFloating()
    }
    func ownsFloating(_ controller: AgentSettingsPageController) -> Bool { floating.values.contains { $0.1 === controller } }
    func requireFloatingAvailable(taskID: String, root: String) throws {
        guard !coldFloating.contains(where: { $0.taskID == taskID && $0.tab.root == root }) else {
            throw PetError("此独立窗口有待恢复内容，请从“窗口”菜单恢复；原草稿已保留")
        }
    }
    func registerFloating(_ controller: AgentSettingsPageController, taskID: String, root: String, tab: AgentWorkspaceRecovery.Tab? = nil) {
        guard !stopped, !ownsFloating(controller) else { return }
        let tab = tab ?? .init(root: root, title: controller.window?.title ?? "")
        floating[tab.id] = (.init(taskID: taskID, tab: tab, frame: nil), controller)
        coldFloating.removeAll { $0.tab.id == tab.id }
        let change: () -> Void = { [weak self] in self?.changed() }
        (controller as? AgentRecordWindow)?.onWorkspaceChange = change
        (controller as? AgentOfficeWindow)?.onWorkspaceChange = change
        (controller as? AgentCanvasWindow)?.onWorkspaceChange = change
        (controller as? AgentBrowserWindow)?.onWorkspaceChange = change
        if let window = controller.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(floatingGeometryChanged(_:)), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(floatingWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        }
        changed()
    }
    @discardableResult func releaseFloating(_ controller: AgentSettingsPageController) -> AgentWorkspaceRecovery.FloatingPage? {
        guard let entry = floating.first(where: { $0.value.1 === controller }) else { return nil }
        floating[entry.key] = nil
        if let window = controller.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        changed(); return entry.value.0
    }
    @objc private func floatingGeometryChanged(_ notification: Notification) { changed() }
    @objc private func floatingWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let controller = floating.values.first(where: { $0.1.window === window })?.1 else { return }
        releaseFloating(controller)
    }
    func restoreFloating() {
        guard !stopped, !disabled else { return }
        restoreKnowledge()
        restoreSettings()
        if coldKnowledge?.active != true, coldSettings?.active != true, coldSettingsNavigation == nil { restoreAutomation() }
        for task in owner?.taskWorkspace.recoveryLayouts ?? [] { for tab in task.tabs where tab.hasIndependentChild == true {
            guard let root = AgentTaskWorkspace.Root(key: tab.root), owner?.taskWorkspace.recoveryController(taskID: task.taskID, root: root) == nil else { continue }
            restore(task: task.taskID, tab: tab, activate: false)
        } }
        for metadata in coldFloating where roots[metadata.tab.id] == nil {
            let pageID = metadata.tab.id
            roots[pageID] = Task { @MainActor [weak self] in
                guard let self, let owner else { return }
                defer { roots[pageID] = nil }
                do {
                    let journal = journal, windowID = id
                    let loaded = try await journal.loadPage(windowID: windowID, pageID: pageID, taskID: metadata.taskID)
                    guard !stopped, coldFloating.contains(where: { $0.tab.id == pageID }) else { return }
                    guard let loaded else { throw PetError("独立窗口缺少恢复内容，原记录已保留") }
                    pageHashes[pageID] = loaded.saved.hash; pages[pageID] = loaded.saved.value
                    let controller = try await owner.materializeFloatingRecovery(metadata, loaded: loaded)
                    registerFloating(controller, taskID: metadata.taskID, root: metadata.tab.root, tab: metadata.tab)
                    if let old = floatingFailures.removeValue(forKey: pageID) { owner.clearWorkspaceRecoveryStatus(old, prefix: "") }
                } catch {
                    let message = "独立窗口未恢复，原草稿已保留；可从“窗口”菜单重试：" + error.localizedDescription
                    floatingFailures[pageID] = message; owner.setStatus(message, error: true)
                }
            }
        }
    }
    func restoreKnowledge() {
        guard !stopped, !disabled, let value = coldKnowledge, roots["knowledge"] == nil else { return }
        roots["knowledge"] = Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            defer { roots["knowledge"] = nil }
            do {
                try owner.materializeKnowledgeRecovery(value)
                coldKnowledge = nil
                if let knowledgeFailure { owner.clearWorkspaceRecoveryStatus(knowledgeFailure, prefix: "") }
                knowledgeFailure = nil; changed()
            } catch {
                let message = "知识阅读记录未恢复，原记录已保留；可从“窗口”菜单重试：" + error.localizedDescription
                knowledgeFailure = message; owner.setStatus(message, error: true)
            }
        }
    }
    func restoreSettings() {
        guard !stopped, !disabled, coldSettings != nil || coldSettingsNavigation != nil, roots["settings"] == nil else { return }
        roots["settings"] = Task { @MainActor [weak self] in
            guard let self, let owner else { return }; defer { roots["settings"] = nil }
            var failure: Error?
            if let value = coldSettings {
                do { try owner.materializeSettingsRecovery(value); coldSettings = nil; changed() }
                catch { failure = error }
            }
            if failure == nil, let navigation = coldSettingsNavigation {
                do {
                    try owner.materializeSettingsNavigation(navigation)
                    coldSettingsNavigation = nil; changed()
                } catch { failure = error }
            }
            if let failure {
                let message = "设置草稿未恢复，原记录已保留；可从原分类或“窗口”菜单重试：" + failure.localizedDescription
                settingsFailure = message; owner.setStatus(message, error: true)
            } else {
                if let settingsFailure { owner.clearWorkspaceRecoveryStatus(settingsFailure, prefix: "") }
                settingsFailure = nil
            }
        }
    }
    func loadMarketReviewCopy(_ hash: String) async throws -> Data {
        try await journal.loadMarketReviewCopy(windowID: id, hash: hash)
    }
    func restoreAutomation() {
        guard !stopped, !disabled, let value = coldAutomation, roots["automation"] == nil else { return }
        roots["automation"] = Task { @MainActor [weak self] in
            guard let self, let owner else { return }; defer { roots["automation"] = nil }
            do {
                try owner.materializeAutomationRecovery(value)
                coldAutomation = nil
                if let automationFailure { owner.clearWorkspaceRecoveryStatus(automationFailure, prefix: "") }
                automationFailure = nil; changed()
            } catch {
                let message = "自动化草稿未恢复，原记录已保留：" + error.localizedDescription
                automationFailure = message; owner.setStatus(message, error: true)
            }
        }
    }
    func hasAutomationDraft(for ids: Set<String>) -> Bool {
        coldAutomation?.context.taskID.map(ids.contains) == true
    }
    func prepareFloating(preserving: Bool) async -> Bool {
        for controller in floatingControllers {
            if preserving, preservedEditors.contains(ObjectIdentifier(controller)) {
                if let record = controller as? AgentRecordWindow { guard record.prepareWorkspaceNavigation() else { return false }; continue }
                if let office = controller as? AgentOfficeWindow { guard office.prepareWorkspaceNavigation() else { return false }; continue }
                if let canvas = controller as? AgentCanvasWindow { guard canvas.prepareWorkspaceNavigation() else { return false }; continue }
                if let browser = controller as? AgentBrowserWindow { guard browser.prepareWorkspaceNavigation() else { return false }; continue }
            }
            guard await controller.prepareForWorkspaceClose() else { controller.presentingWindow?.makeKeyAndOrderFront(nil); return false }
        }
        return true
    }
    func finish() {
        let controllers = floatingControllers
        stop(); NotificationCenter.default.removeObserver(self); floating.removeAll()
        for controller in controllers { controller.endSettingsHosting() }
    }
    func removeFloatingTasks(_ ids: Set<String>) {
        coldFloating.removeAll { ids.contains($0.taskID) }
        if var knowledge = coldKnowledge {
            knowledge.readers.removeAll { ids.contains($0.taskID) }
            coldKnowledge = ids.contains(knowledge.identity) || !knowledge.hasContent ? nil : knowledge
        }
        for (_, entry) in Array(floating) where ids.contains(entry.0.taskID) { releaseFloating(entry.1); entry.1.endSettingsHosting() }
        changed()
    }
    private func loadTabStates(_ tasks: [AgentWorkspaceRecovery.TaskLayout]) {
        let journal = journal, windowID = id
        tabStateJob = Task { @MainActor [weak self] in
            guard let self else { return }; defer { tabStateJob = nil }
            let result = await journal.tabStates(tasks, windowID: windowID)
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
                for (_, tab, controller) in editors {
                    if let record = controller as? AgentRecordWindow {
                        let page = try await record.captureWorkspaceRecovery()
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
                    } else if let browser = controller as? AgentBrowserWindow {
                        let page = try await browser.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    } else if let attachment = controller as? AgentAttachmentWindow {
                        let page = try attachment.captureWorkspaceRecovery()
                        if pages[tab.id] != page { try await persist(page, asset: nil, pageID: tab.id) }
                    } else if let git = controller as? AgentGitWindow, let page = try git.captureWorkspaceRecovery(persistClean: pages[tab.id] != nil), pages[tab.id] != page {
                        try await persist(page, asset: nil, pageID: tab.id)
                    }
                }
                let journal = journal
                var layout = AgentWorkspaceRecovery.Window(id: id, number: owner.taskWindowNumber, taskID: owner.agentTaskID,
                    frame: owner.window.map { .init(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }, tasks: owner.taskWorkspace.recoveryLayouts)
                layout.floating = coldFloating + floating.values.map { metadata, controller in
                    var value = metadata
                    value.tab.title = controller.window?.title ?? metadata.tab.title
                    value.tab.hasIndependentChild = (controller as? AgentRecordWindow)?.hasIndependentWorkspaceChild == true || (controller as? AgentBrowserWindow)?.hasIndependentAnnotation == true ? true : nil
                    value.frame = controller.window.map { .init(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
                    return value
                }.sorted { $0.tab.id < $1.tab.id }
                if let coldKnowledge { layout.knowledge = coldKnowledge }
                else { layout.knowledge = try await owner.knowledgePageHost.captureWorkspaceRecovery(active: owner.isShowingKnowledge) }
                if let coldSettings { layout.settings = coldSettings }
                else { layout.settings = try owner.captureSettingsRecovery() }
                layout.settingsNavigation = coldSettingsNavigation ?? owner.captureSettingsNavigation()
                layout.conversationPositions = owner.captureConversationPositions()
                layout.automation = try coldAutomation ?? owner.captureAutomationRecovery()
                let marketCopy = coldSettings == nil ? (owner.settingsRecoveryControllers.last as? AgentPluginReviewPage)?.marketCopy : nil
                let expected = layoutHash, capturedLayout = layout
                let saved = try await journal.saveWindow(capturedLayout, expected: expected, marketCopy: marketCopy)
                layoutHash = saved.hash; previous = saved.value
                if !terminalRecoveryReadOnly, let terminals = owner.captureTerminalLayout(windowID: id) {
                    let appearance = terminalAppearance(for: terminals, preference: owner.terminalAppearancePreference)
                    if terminals != savedTerminals?.value {
                        savedTerminals = try await journal.saveTerminals(terminals, expected: savedTerminals?.hash)
                    }
                    if let appearance, appearance != savedTerminalAppearance?.value {
                        savedTerminalAppearance = try await journal.saveTerminalAppearance(appearance, expected: savedTerminalAppearance?.hash)
                    }
                }
                savedRevision = targetRevision
                if let failure { owner.clearWorkspaceRecoveryStatus(failure.localizedDescription) }
                failure = nil
                preservedEditors = Set(editors.compactMap { _, tab, controller in
                    if let record = controller as? AgentRecordWindow, record.canPreserveForQuit { return ObjectIdentifier(record) }
                    if let office = controller as? AgentOfficeWindow, office.canPreserveForQuit { return ObjectIdentifier(office) }
                    if let canvas = controller as? AgentCanvasWindow, canvas.canPreserveForQuit { return ObjectIdentifier(canvas) }
                    if let mcp = controller as? AgentMCPContentWindow, mcp.canPreserveForQuit { return ObjectIdentifier(mcp) }
                    if let editor = controller as? AgentEditResendWindow, editor.canPreserveForQuit { return ObjectIdentifier(editor) }
                    if let browser = controller as? AgentBrowserWindow, browser.canPreserveForQuit { return ObjectIdentifier(browser) }
                    if let git = controller as? AgentGitWindow, git.canPreserveForQuit, pages[tab.id]?.dirty == true { return ObjectIdentifier(git) }
                    return nil
                })
                preservedEditors.formUnion(owner.knowledgePageHost.recoveryReaders.filter(\.canPreserveForQuit).map(ObjectIdentifier.init))
                if coldSettings == nil, layout.settings != nil { preservedEditors.formUnion(owner.settingsRecoveryControllers.map(ObjectIdentifier.init)) }
                if coldAutomation == nil, layout.automation != nil, let manager = owner.automationWindow { preservedEditors.insert(ObjectIdentifier(manager)) }
                preservedEditors.formUnion(owner.knowledgePageHost.recoveryEditors.compactMap { editor in
                    if let cards = editor as? AgentKnowledgeCardWindow, cards.canPreserveForQuit { return ObjectIdentifier(cards) }
                    if let index = editor as? AgentKnowledgeWindow, index.canPreserveForQuit { return ObjectIdentifier(index) }
                    if let library = editor as? AgentKnowledgeLibraryWindow, library.canPreserveForQuit { return ObjectIdentifier(library) }
                    return nil
                })
                for (_, _, controller) in editors {
                    if let browser = controller as? AgentBrowserWindow, preservedEditors.contains(ObjectIdentifier(browser)),
                       let annotation = browser.recoveryAnnotation, annotation.canPreserveForQuit { preservedEditors.insert(ObjectIdentifier(annotation)) }
                    if let git = controller as? AgentGitWindow, preservedEditors.contains(ObjectIdentifier(git)) {
                        if let remote = git.recoveryRemoteForm, remote.canPreserveForQuit { preservedEditors.insert(ObjectIdentifier(remote)) }
                        if let creation = git.recoveryWorktreeForm, creation.canPreserveForQuit { preservedEditors.insert(ObjectIdentifier(creation)) }
                    }
                }
                let records = editors.compactMap { $0.2 as? AgentRecordWindow } + owner.knowledgePageHost.recoveryReaders
                for record in records where preservedEditors.contains(ObjectIdentifier(record)) {
                    if let plan = record.recoveryWikiPlan, plan.canPreserveForQuit, try plan.captureWorkspaceRecovery() != nil { preservedEditors.insert(ObjectIdentifier(plan)) }
                }
            }
        } catch { failure = error; preservedEditors = []; owner.setStatus("工作区恢复未保存：" + error.localizedDescription, error: true) }
    }
    private func persist(_ page: AgentWorkspaceRecovery.Page, asset: URL?, pageID: String) async throws {
        let journal = journal, windowID = id, hash = pageHashes[pageID]
        let saved = try await journal.savePage(page, asset: asset, windowID: windowID, pageID: pageID, expected: hash)
        // Keep each successful revision if a later page or layout fails.
        pageHashes[pageID] = saved.hash; pages[pageID] = saved.value
        owner?.taskWorkspace.applyRecoveredTabStates([pageID: saved.value.dirty])
    }
    private func terminalAppearance(for layout: AgentTerminalLayout, preference: AgentTerminalAppearance?) -> AgentTerminalAppearanceRecord? {
        guard !terminalAppearanceReadOnly, let preference, preference == .application || savedTerminalAppearance != nil else { return nil }
        return AgentTerminalAppearanceRecord(windowID: id, preference: preference, fallbackDark: layout.dark)
    }
    func flush() async throws {
        guard !disabled else { return }
        for root in Array(roots.values) { await root.value }
        // Read the latest media position even between throttled time events.
        if editors.contains(where: { ($0.2 as? AgentRecordWindow)?.hasVideoPlayback == true }) || owner?.knowledgePageHost.recoveryReaders.contains(where: \.hasVideoPlayback) == true { revision &+= 1 }
        if editors.contains(where: { ($0.2 as? AgentGitWindow)?.recoveryWorktreeForm?.hasDraft == true }) { revision &+= 1 }
        if !terminalRecoveryReadOnly, let owner, let terminals = owner.captureTerminalLayout(windowID: id) {
            let appearance = terminalAppearance(for: terminals, preference: owner.terminalAppearancePreference)
            if terminals != savedTerminals?.value || (appearance != nil && appearance != savedTerminalAppearance?.value) { revision &+= 1 }
        }
        if let tabStateJob { await tabStateJob.value }
        if let job { await job.value }
        if savedRevision != revision { await savePending() }
        if let failure { throw failure }
    }
    func stop() { stopped = true; tabStateJob?.cancel(); tabStateJob = nil; preservedEditors = []; NotificationCenter.default.removeObserver(self) }
    func markClosed() async throws {
        guard !disabled else { stop(); return }
        try await flush()
        guard var layout = previous else { stop(); return }
        let closingRevision = revision; closing = true
        defer { closing = false; if !stopped, revision != closingRevision { changed() } }
        layout.closed = true
        let journal = journal, expected = layoutHash
        let saved = try await journal.saveWindow(layout, expected: expected)
        layoutHash = saved.hash; previous = saved.value
        guard revision == closingRevision else { throw PetError("关闭期间内容已变化，请重新检查后关闭") }
        stop()
    }
    private func restore(task: String, tab: AgentWorkspaceRecovery.Tab, activate: Bool = true) {
        guard !stopped, !disabled, roots[tab.id] == nil else { return }
        roots[tab.id] = Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            defer { roots[tab.id] = nil; owner.taskWorkspace.retryRecovery(tab.id) }
            do {
                let journal = journal, windowID = id
                let loaded = try await journal.loadPage(windowID: windowID, pageID: tab.id, taskID: task)
                guard !stopped, (!activate || owner.agentTaskID == task), owner.taskWorkspace.recoveryLayouts.contains(where: { $0.taskID == task && $0.tabs.contains(where: { $0.id == tab.id }) }) else { return }
                if let loaded { pageHashes[tab.id] = loaded.saved.hash; pages[tab.id] = loaded.saved.value }
                try await owner.materializeRecoveryRoot(task: task, tab: tab, loaded: loaded, activate: activate)
                owner.taskWorkspace.reportRecoveryFailure(tab.id, message: nil); changed()
            } catch {
                let message = "标签恢复失败，原草稿已保留：" + error.localizedDescription
                owner.taskWorkspace.reportRecoveryFailure(tab.id, message: error.localizedDescription)
                owner.setStatus(message, error: true)
            }
        }
    }
}

@MainActor extension AppDelegate {
    @objc func restoreFloatingWorkspaceWindows() { for window in taskControls { window.workspaceSession?.restoreFloating() } }
    func flushWorkspaceWindows() async -> Bool {
        repeat {
            for window in taskControls { if !(await window.flushWorkspaceRecovery()) { return false } }
        } while taskControls.contains { $0.workspaceSession?.isCurrent == false }
        return true
    }
    var workspaceRecoveryEnabled: Bool { checkDirectory == nil || usesSettingsRecoveryCheck || (CommandLine.arguments.contains("--manual-ui") && CommandLine.arguments.contains("--terminal-recovery-ui")) || CommandLine.arguments.contains("--knowledge-editor-recovery-check") || CommandLine.arguments.contains("--knowledge-editor-recovery-ui") || ((CommandLine.arguments.contains("--knowledge-reader-recovery-check") || CommandLine.arguments.contains("--knowledge-reader-recovery-ui") || CommandLine.arguments.contains("--knowledge-source-recovery-check")) || CommandLine.arguments.contains("--knowledge-source-recovery-ui") || CommandLine.arguments.contains("--workspace-source-recovery-check")) || CommandLine.arguments.contains("--workspace-source-recovery-ui") || CommandLine.arguments.contains("--workspace-text-viewport-check") || CommandLine.arguments.contains("--workspace-text-viewport-ui") || CommandLine.arguments.contains("--workspace-child-recovery-check") || CommandLine.arguments.contains("--workspace-child-recovery-ui") || CommandLine.arguments.contains("--workspace-floating-recovery-check") || CommandLine.arguments.contains("--workspace-floating-recovery-ui") || CommandLine.arguments.contains("--workspace-video-recovery-check") || CommandLine.arguments.contains("--workspace-video-recovery-ui") || CommandLine.arguments.contains("--workspace-browser-recovery-check") || CommandLine.arguments.contains("--workspace-browser-recovery-ui") || CommandLine.arguments.contains("--workspace-edit-recovery-check") || CommandLine.arguments.contains("--workspace-edit-recovery-ui") || CommandLine.arguments.contains("--workspace-mcp-recovery-check") || CommandLine.arguments.contains("--workspace-mcp-recovery-ui") || CommandLine.arguments.contains("--workspace-canvas-recovery-check") || CommandLine.arguments.contains("--workspace-canvas-recovery-ui") || CommandLine.arguments.contains("--workspace-office-recovery-check") || CommandLine.arguments.contains("--workspace-office-recovery-ui") || CommandLine.arguments.contains("--workspace-recovery-lifecycle-check") || CommandLine.arguments.contains("--workspace-recovery-ui") }
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
