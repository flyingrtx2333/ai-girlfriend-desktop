import AppKit
import BlueFatFishTerminal

@MainActor final class AgentTerminalSplitView: NSSplitView, NSSplitViewDelegate {
    let conversation = NSView()
    private weak var terminal: NSView?
    private var preferredHeight: CGFloat?
    private var showsApproval = false
    private var minimumTerminalHeight: CGFloat { showsApproval ? 150 : 162 }

    private var minimumConversationHeight: CGFloat {
        min(showsApproval ? 320 : 248, max(0, bounds.height - minimumTerminalHeight - dividerThickness))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(conversation)
        setHoldingPriority(.defaultLow, forSubviewAt: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var recoveryHeight: Double? {
        let current = terminal.map { Double($0.frame.height) }.flatMap { $0 > 0 ? $0 : nil }
        return current ?? preferredHeight.map { Double($0) }
    }
    func restoreHeight(_ value: Double?) { preferredHeight = value.map { CGFloat($0) } }

    func showTerminal(_ view: NSView?) {
        guard terminal !== view else { return }
        if let terminal {
            if terminal.frame.height > 0 { preferredHeight = terminal.frame.height }
            removeArrangedSubview(terminal)
            terminal.removeFromSuperview()
        }
        terminal = view
        if let view {
            addArrangedSubview(view)
            setHoldingPriority(.defaultHigh, forSubviewAt: 1)
            let height = bounds.height
            let target = preferredHeight ?? min(330, max(172, height * 0.41))
            adjustSubviews()
            setPosition(max(minimumConversationHeight, height - target - dividerThickness), ofDividerAt: 0)
        } else { adjustSubviews() }
    }

    func reserveApprovalSpace(_ visible: Bool) {
        showsApproval = visible
        guard visible, terminal != nil, conversation.frame.height < minimumConversationHeight else { return }
        setPosition(minimumConversationHeight, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposed, minimumConversationHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposed, max(minimumConversationHeight, bounds.height - minimumTerminalHeight - dividerThickness))
    }
}

@MainActor private final class AgentTerminalPaneSplit: NSSplitView {
    private var restoredFraction: Double?
    init(vertical: Bool, fraction: Double? = nil) {
        restoredFraction = fraction
        super.init(frame: .zero)
        isVertical = vertical; dividerStyle = .thin
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var length: CGFloat { (isVertical ? bounds.width : bounds.height) - dividerThickness }
    var fraction: Double {
        if let restoredFraction { return restoredFraction }
        guard let first = arrangedSubviews.first, length > 0 else { return 0.5 }
        return max(0, min(1, Double((isVertical ? first.frame.width : first.frame.height) / length)))
    }
    override func layout() {
        super.layout()
        if let restoredFraction, window != nil, length > 1, arrangedSubviews.count == 2 {
            self.restoredFraction = nil
            setPosition(length * CGFloat(restoredFraction), ofDividerAt: 0)
        }
    }
}

@MainActor private final class AgentTerminalPane: NSView {
    private(set) var surface: TerminalSurface?
    private(set) var record: AgentTerminalLayout.Pane
    private var suspending = false
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let header = AgentThemeView(fill: AgentWorkbenchTheme.surface)
    private let terminalHost = NSView()
    private let start = AgentWorkbenchButton(), close = AgentWorkbenchButton()
    var onStart: (() -> Void)?
    var onClose: (() -> Void)?
    var number: Int { record.number }
    var id: UUID { record.id }
    var name: String { "终端 \(number)" }
    var pid: pid_t { surface?.pid ?? 0 }
    var startDirectory: String { record.directory }
    var focusView: NSView { pid > 0 ? surface?.view ?? start : start }

    init(_ record: AgentTerminalLayout.Pane) {
        self.record = record
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        title.stringValue = name
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.toolTip = record.directory
        state.font = .systemFont(ofSize: 11)
        state.textColor = AgentWorkbenchTheme.secondaryText
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        AgentWorkbenchTheme.toolbar(close, title: "关闭\(name)", symbol: "xmark")
        close.target = self
        close.action = #selector(closePane)
        AgentWorkbenchTheme.toolbar(start, title: "启动\(name)", symbol: "play.fill")
        start.target = self; start.action = #selector(startPane)
        let row = NSStackView(views: [title, state, NSView(), start, close])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        let rule = AgentWorkbenchTheme.rule()
        for view in [header, rule, terminalHost] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 9), row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor), rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalHost.topAnchor.constraint(equalTo: rule.bottomAnchor), terminalHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLifecycle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func closePane() { onClose?() }
    @objc private func startPane() { onStart?() }

    func select(_ selected: Bool) {
        title.textColor = selected ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.secondaryText
    }

    func rememberDirectory() {
        if let directory = AgentTerminalLayout.directory(of: pid) { record.directory = directory; title.toolTip = directory }
    }
    func mount(_ next: TerminalSurface) {
        surface?.view.removeFromSuperview()
        surface = next; record.exitCode = nil
        let view = next.view
        view.frame = terminalHost.bounds; view.autoresizingMask = [.width, .height]; terminalHost.addSubview(view)
        next.onIssue = { [weak self] message in self?.state.stringValue = message }
        refreshLifecycle()
    }
    func suspend() {
        guard pid > 0 else { return }
        rememberDirectory(); suspending = true; surface?.stop()
    }
    func exited(_ code: Int32) {
        record.exitCode = suspending ? nil : code; suspending = false; refreshLifecycle()
    }
    private func refreshLifecycle() {
        start.isHidden = pid > 0
        state.stringValue = pid > 0 ? "" : record.exitCode.map { "已退出（\($0)）" } ?? "待启动"
    }
}

@MainActor final class AgentTerminalPanel: AgentThemeView {
    @MainActor private final class Tab {
        let number: Int
        var title: String { "终端 \(number)" }
        var root: NSView
        var panes: [AgentTerminalPane]
        var active: AgentTerminalPane

        init(number: Int, root: NSView, panes: [AgentTerminalPane], active: AgentTerminalPane) {
            self.number = number; self.root = root; self.panes = panes; self.active = active
        }
    }

    @MainActor private final class TaskTerminals {
        let id: String
        let workspace: String?
        let workspaceScope:AgentWorkspaceScope?
        let directory: URL
        var tabs: [Tab] = []
        var index = 0
        var shown = true

        init(task: AgentTaskRecord, directory: URL) {
            id = task.id
            workspace = task.workspace
            workspaceScope = task.workspaceScope
            self.directory = directory
        }

        var selected: Tab? { tabs.indices.contains(index) ? tabs[index] : nil }
    }

    private weak var store: AgentStore?
    private let checkHome: URL?
    private var states: [String: TaskTerminals] = [:]
    private var currentID: String?
    private var mounted: NSView?
    private var nextNumber = 1
    private var dark = false
    private let maximumPanes = AgentTerminalLayout.maximumPanes
    private let tabs = NSPopUpButton(frame: .zero, pullsDown: false)
    private let body = NSView()
    private let path = NSTextField(labelWithString: "")
    private let add = AgentWorkbenchButton(), right = AgentWorkbenchButton(), down = AgentWorkbenchButton()
    private let theme = AgentWorkbenchButton(), hide = AgentWorkbenchButton()
    var onHide: (() -> Void)?
    var onMonitorChange: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var isShown: Bool { current?.shown == true && current?.selected != nil }
    private var current: TaskTerminals? { currentID.flatMap { states[$0] } }
    private var paneCount: Int { states.values.reduce(0) { count, state in count + state.tabs.reduce(0) { $0 + $1.panes.count } } }
    func monitorEntries(taskID: String) -> [AgentMonitorEntry] {
        (states[taskID]?.tabs ?? []).flatMap(\.panes).map { pane in
            let status = pane.record.exitCode.map { " · 已退出（\($0)）" } ?? (pane.pid == 0 ? " · 待启动" : "")
            return AgentMonitorEntry(id: pane.id.uuidString, title: pane.name + status, detail: pane.pid > 0 ? "PID \(pane.pid)" : pane.startDirectory)
        }
    }
    func openMonitorEntry(_ id: String, taskID: String) throws {
        guard currentID == taskID, let state = current, let index = state.tabs.firstIndex(where: { $0.panes.contains { $0.id.uuidString == id } }), let pane = state.tabs[index].panes.first(where: { $0.id.uuidString == id }) else { throw PetError("此任务的终端会话已关闭") }
        state.index = index; state.tabs[index].active = pane; state.shown = true; render(); focus(); onLayoutChange?()
    }

    init(store: AgentStore, checkHome: URL?) {
        self.store = store
        self.checkHome = checkHome
        super.init(frame: .zero)
        setAccessibilityLabel("任务终端")
        fill = AgentWorkbenchTheme.surface
        tabs.setAccessibilityLabel("终端会话")
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 12, weight: .medium)
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        path.font = .systemFont(ofSize: 11)
        path.textColor = AgentWorkbenchTheme.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, label, symbol, action) in [
            (add, "新建终端", "plus", #selector(addTab)),
            (right, "向右分屏", "rectangle.split.2x1", #selector(splitRight)),
            (down, "向下分屏", "rectangle.split.1x2", #selector(splitDown)),
            (theme, "切换为深色终端", "moon", #selector(toggleTheme)),
            (hide, "收起终端面板", "chevron.down", #selector(hidePanel)),
        ] {
            AgentWorkbenchTheme.toolbar(button, title: label, symbol: symbol)
            button.target = self
            button.action = action
        }
        let bar = NSStackView(views: [AgentSettingsPopupFrame(tabs, outlined: false), path, NSView(), add, right, down, theme, hide])
        bar.alignment = .centerY
        bar.spacing = 4
        let rule = AgentWorkbenchTheme.rule()
        for view in [bar, rule, body] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        body.wantsLayer = true
        body.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 34),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor), rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: rule.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func available(_ task: AgentTaskRecord) -> Bool {
        !task.archived && task.kind != "hook" && !task.isProjectDocumentation && task.automation == nil && task.agent?.ownerID == nil
    }

    private func taskIsAvailable(_ task: AgentTaskRecord, store: AgentStore) -> Bool {
        Self.available(task) && store.organization.archiveID(task.organizationWorkspace, mode: task.organizationMode) == nil
    }

    func selectTask(_ task: AgentTaskRecord?) {
        guard let store else { return }
        for id in Array(states.keys) {
            guard let state = states[id] else { continue }
            if let record = store.task(id), taskIsAvailable(record, store: store), record.workspace == state.workspace, record.workspaceScope == state.workspaceScope { continue }
            closeState(id)
            onLayoutChange?()
        }
        let id = task?.id
        if currentID != id || mounted !== current?.selected?.root {
            currentID = id
            render()
        }
    }

    func open() throws {
        guard let store, let id = currentID, let task = store.task(id), taskIsAvailable(task, store: store) else {
            throw PetError("当前任务不能打开终端")
        }
        if let state = current {
            state.shown = true
        } else {
            let directory = try task.workspace.map { try AgentFiles(workspace: $0).root } ?? store.terminalTaskDirectory(id)
            let state = TaskTerminals(task: task, directory: directory)
            let pane = try makePane(for: state)
            state.tabs = [Tab(number: pane.number, root: pane, panes: [pane], active: pane)]
            states[id] = state
        }
        render(); onLayoutChange?()
    }

    @objc func hidePanel() {
        current?.shown = false
        onHide?(); onLayoutChange?()
    }

    func focus() {
        if let pane = current?.selected?.active { window?.makeFirstResponder(pane.focusView) }
    }

    private func makePane(for state: TaskTerminals) throws -> AgentTerminalPane {
        guard paneCount < maximumPanes, nextNumber < Int.max - 1 else { throw PetError("终端数量已达上限") }
        let pane = AgentTerminalPane(.init(number: nextNumber, directory: state.directory.path))
        bind(pane, taskID: state.id)
        try launch(pane, in: state)
        nextNumber += 1
        return pane
    }

    private func bind(_ pane: AgentTerminalPane, taskID: String) {
        pane.onClose = { [weak self, weak pane] in if let pane { self?.close(pane, taskID: taskID) } }
        pane.onStart = { [weak self, weak pane] in
            guard let self, let pane, let state = states[taskID], let tab = state.selected, tab.panes.contains(where: { $0 === pane }) else { return }
            do {
                try launch(pane, in: state)
                tab.active = pane
                render(); focus(); onLayoutChange?()
            } catch { showIssue(error) }
        }
    }

    private func launch(_ pane: AgentTerminalPane, in state: TaskTerminals) throws {
        guard pane.pid == 0, let store, let task = store.task(state.id), taskIsAvailable(task, store: store),
              task.workspace == state.workspace, task.workspaceScope == state.workspaceScope else { throw PetError("任务或终端状态已变化") }
        let root = try task.workspace.map { try AgentFiles(workspace: $0).root } ?? store.terminalTaskDirectory(state.id)
        guard root == state.directory else { throw PetError("任务目录已变化，原终端记录仍保留") }
        guard let directory = try? AgentFiles(workspace: pane.startDirectory).root, directory.path == pane.startDirectory else {
            throw PetError("终端目录暂不可用，请恢复目录后重试")
        }
        let surface = TerminalSurface(); surface.setDark(dark)
        let operation = pane.id
        let taskID = state.id
        let retention = store.worktreeRetention
        surface.onExit = { [weak self, weak pane, weak retention] code in
            retention?.setNativeOperation(operation, taskID: taskID, busy: false)
            pane?.exited(code)
            self?.onMonitorChange?(); self?.onLayoutChange?()
        }
        do { try surface.start(in: directory, checkHome: checkHome) }
        catch { throw PetError("终端无法启动。\(error.localizedDescription)") }
        retention.setNativeOperation(operation, taskID: taskID, busy: true)
        surface.onFocus = { [weak self, weak pane] in
            if let self, let pane, let tab = current?.selected, tab.panes.contains(where: { $0 === pane }) {
                let focusedDifferentPane = tab.active !== pane
                tab.active = pane
                tab.panes.forEach { $0.select($0 === pane) }
                updatePath()
                if focusedDifferentPane { onLayoutChange?() }
            }
        }
        pane.mount(surface)
    }

    @objc private func addTab() {
        guard let state = current else { return }
        do {
            let pane = try makePane(for: state)
            state.tabs.append(Tab(number: pane.number, root: pane, panes: [pane], active: pane))
            state.index = state.tabs.count - 1
            render()
            focus(); onLayoutChange?()
        } catch { showIssue(error) }
    }

    @objc private func selectTab() {
        guard let state = current, state.tabs.indices.contains(tabs.indexOfSelectedItem) else { return }
        state.index = tabs.indexOfSelectedItem
        render()
        focus(); onLayoutChange?()
    }

    @objc private func splitRight() { split(vertical: true) }
    @objc private func splitDown() { split(vertical: false) }

    private func split(vertical: Bool) {
        guard let state = current, let tab = state.selected else { return }
        let previous = tab.active
        let size = vertical ? previous.bounds.width : previous.bounds.height
        guard size >= (vertical ? 220 : 142) else {
            showIssue(PetError(vertical ? "请加宽面板后再向右分屏" : "请增高面板后再向下分屏"))
            return
        }
        do {
            let pane = try makePane(for: state)
            let split = AgentTerminalPaneSplit(vertical: vertical)
            replace(previous, with: split, in: tab)
            split.addArrangedSubview(previous)
            split.addArrangedSubview(pane)
            split.adjustSubviews()
            split.setPosition(size / 2, ofDividerAt: 0)
            tab.panes.append(pane)
            tab.active = pane
            render()
            focus(); onLayoutChange?()
        } catch { showIssue(error) }
    }

    private func replace(_ old: NSView, with new: NSView, in tab: Tab) {
        let frame = old.frame
        if let parent = old.superview as? NSSplitView, let index = parent.arrangedSubviews.firstIndex(of: old) {
            parent.removeArrangedSubview(old)
            old.removeFromSuperview()
            new.frame = frame
            parent.insertArrangedSubview(new, at: index)
            parent.adjustSubviews()
        } else {
            old.removeFromSuperview()
            new.frame = frame
            tab.root = new
        }
    }

    private func close(_ pane: AgentTerminalPane, taskID: String) {
        guard let state = states[taskID], let index = state.tabs.firstIndex(where: { tab in tab.panes.contains { $0 === pane } }) else { return }
        let tab = state.tabs[index]
        pane.surface?.stop()
        if let parent = pane.superview as? NSSplitView, let remaining = parent.arrangedSubviews.first(where: { $0 !== pane }) {
            parent.removeArrangedSubview(remaining)
            remaining.removeFromSuperview()
            replace(parent, with: remaining, in: tab)
            pane.removeFromSuperview()
            tab.panes.removeAll { $0 === pane }
            if tab.active === pane, let first = tab.panes.first { tab.active = first }
        } else {
            state.tabs.remove(at: index)
            if index < state.index { state.index -= 1 }
            state.index = max(0, min(state.index, state.tabs.count - 1))
        }
        if state.tabs.isEmpty { states.removeValue(forKey: taskID) }
        render()
        if isShown { focus() } else { onHide?() }
        onLayoutChange?()
    }

    private func closeState(_ id: String) {
        let state = states.removeValue(forKey: id)
        state?.tabs.flatMap(\.panes).forEach { $0.surface?.stop() }
    }

    func stopAll() {
        for id in Array(states.keys) { closeState(id) }
        render(); onLayoutChange?()
    }

    func suspendAll() {
        for state in states.values { state.tabs.flatMap(\.panes).forEach { $0.suspend() } }
        onLayoutChange?()
    }

    @objc private func toggleTheme() {
        dark.toggle()
        refreshTheme()
        for state in states.values { state.tabs.flatMap(\.panes).forEach { $0.surface?.setDark(dark) } }
        focus(); onLayoutChange?()
    }
    private func refreshTheme() {
        let title = dark ? "切换为浅色终端" : "切换为深色终端"
        theme.image = NSImage(systemSymbolName: dark ? "sun.max" : "moon", accessibilityDescription: nil)
        theme.image?.size = NSSize(width: 16, height: 16)
        theme.setAccessibilityLabel(title)
        theme.toolTip = title
    }

    private func updatePath() {
        let active = current?.selected?.active
        active?.rememberDirectory()
        path.textColor = AgentWorkbenchTheme.secondaryText
        path.stringValue = active?.startDirectory ?? current?.directory.path ?? ""
        path.toolTip = path.stringValue
    }

    private func render() {
        let state = current
        tabs.removeAllItems()
        tabs.addItems(withTitles: state?.tabs.map(\.title) ?? [])
        if let state, state.selected != nil { tabs.selectItem(at: state.index) }
        updatePath()
        let root = state?.selected?.root
        if mounted !== root {
            // Splitting the old root can move it into the new split view.
            if mounted?.superview === body { mounted?.removeFromSuperview() }
            mounted = root
            if let root {
                root.frame = body.bounds
                root.autoresizingMask = [.width, .height]
                body.addSubview(root)
            }
        }
        let canAdd = state != nil && paneCount < maximumPanes
        add.isEnabled = canAdd
        right.isEnabled = canAdd
        down.isEnabled = canAdd
        if let tab = state?.selected { tab.panes.forEach { $0.select($0 === tab.active) } }
        onMonitorChange?()
    }

    private func showIssue(_ error: Error) {
        path.textColor = AgentDialogStyle.error
        path.stringValue = error.localizedDescription
        path.toolTip = path.stringValue
    }

    func layoutToRestore(windowID: String, height: Double?) -> AgentTerminalLayout? {
        func capture(_ view: NSView) -> AgentTerminalLayout.Split? {
            if let pane = view as? AgentTerminalPane { pane.rememberDirectory(); return .pane(pane.record) }
            guard let split = view as? AgentTerminalPaneSplit, split.arrangedSubviews.count == 2,
                  let first = capture(split.arrangedSubviews[0]), let second = capture(split.arrangedSubviews[1]) else { return nil }
            return .branch(vertical: split.isVertical, fraction: split.fraction, first: first, second: second)
        }
        var records: [AgentTerminalLayout.Task] = []
        for state in states.values.sorted(by: { $0.id < $1.id }) {
            var tabs: [AgentTerminalLayout.Tab] = []
            for tab in state.tabs {
                guard let root = capture(tab.root) else { return nil }
                tabs.append(.init(number: tab.number, active: tab.active.id, root: root))
            }
            records.append(.init(id: state.id, workspace: state.workspace, scope: state.workspaceScope, directory: state.directory.path,
                shown: state.shown, index: state.index, tabs: tabs))
        }
        return AgentTerminalLayout(windowID: windowID, dark: dark, height: height, nextNumber: nextNumber, tasks: records)
    }

    func restore(_ layout: AgentTerminalLayout) {
        guard states.isEmpty, let store else { return }
        dark = layout.dark; nextNumber = layout.nextNumber; refreshTheme()
        for saved in layout.tasks {
            guard let task = store.task(saved.id), taskIsAvailable(task, store: store),
                  task.workspace == saved.workspace, task.workspaceScope == saved.scope else { continue }
            let state = TaskTerminals(task: task, directory: URL(fileURLWithPath: saved.directory, isDirectory: true))
            func restoreNode(_ node: AgentTerminalLayout.Split, panes: inout [AgentTerminalPane]) -> NSView {
                switch node {
                case .pane(let record):
                    let pane = AgentTerminalPane(record)
                    bind(pane, taskID: state.id); panes.append(pane); return pane
                case .branch(let vertical, let fraction, let first, let second):
                    let split = AgentTerminalPaneSplit(vertical: vertical, fraction: fraction)
                    split.addArrangedSubview(restoreNode(first, panes: &panes))
                    split.addArrangedSubview(restoreNode(second, panes: &panes))
                    return split
                }
            }
            for savedTab in saved.tabs {
                var panes: [AgentTerminalPane] = []
                let root = restoreNode(savedTab.root, panes: &panes)
                guard let active = panes.first(where: { $0.id == savedTab.active }) else { continue }
                state.tabs.append(Tab(number: savedTab.number, root: root, panes: panes, active: active))
            }
            guard state.tabs.indices.contains(saved.index), state.tabs.count == saved.tabs.count else { continue }
            state.index = saved.index; state.shown = saved.shown; states[state.id] = state
        }
        render()
    }

    func verificationSnapshot() -> [String: Any] {
        let all = states.values.sorted { $0.id < $1.id }.map { state in
            ["taskID": state.id, "directory": state.directory.path, "shown": state.shown, "tabIndex": state.index,
             "tabs": state.tabs.map { tab in
                 ["active": tab.active.number, "panes": tab.panes.map { pane in
                     ["number": pane.number, "id": pane.id.uuidString, "pid": pane.pid, "width": pane.bounds.width, "height": pane.bounds.height,
                      "directory": pane.startDirectory, "exitCode": pane.record.exitCode as Any? ?? NSNull(),
                      "terminal": pane.surface?.textForVerification() ?? ""]
                 }]
             }] as [String: Any]
        }
        return ["shown": isShown && superview != nil && !isHiddenOrHasHiddenAncestor, "taskID": currentID as Any? ?? NSNull(), "dark": dark, "states": all]
    }
}
