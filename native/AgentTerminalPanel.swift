import AppKit
import BlueFatFishTerminal

@MainActor final class AgentTerminalSplitView: NSSplitView, NSSplitViewDelegate {
    let conversation = NSView()
    private weak var terminal: NSView?
    private var preferredHeight: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(conversation)
        setHoldingPriority(.defaultLow, forSubviewAt: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
            setPosition(max(248, height - target - dividerThickness), ofDividerAt: 0)
        } else { adjustSubviews() }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposed, 248)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposed, max(248, bounds.height - 162 - dividerThickness))
    }
}

@MainActor private final class AgentTerminalPane: NSView {
    let surface = TerminalSurface()
    let number: Int
    let id = UUID()
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let header = AgentThemeView(fill: AgentWorkbenchTheme.surface)
    private let close = AgentWorkbenchButton()
    var onClose: (() -> Void)?
    var name: String { "终端 \(number)" }

    init(number: Int, directory: URL) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        title.stringValue = name
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.toolTip = directory.path
        state.font = .systemFont(ofSize: 11)
        state.textColor = AgentWorkbenchTheme.secondaryText
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        AgentWorkbenchTheme.toolbar(close, title: "关闭\(name)", symbol: "xmark")
        close.target = self
        close.action = #selector(closePane)
        let row = NSStackView(views: [title, state, NSView(), close])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        let rule = AgentWorkbenchTheme.rule()
        for view in [header, rule, surface.view] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 9), row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor), rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            surface.view.topAnchor.constraint(equalTo: rule.bottomAnchor), surface.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        surface.onIssue = { [weak self] message in self?.state.stringValue = message }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func closePane() { onClose?() }

    func select(_ selected: Bool) {
        title.textColor = selected ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.secondaryText
    }

    func exited(_ code: Int32) { state.stringValue = "已退出（\(code)）" }
}

@MainActor final class AgentTerminalPanel: AgentThemeView {
    @MainActor private final class Tab {
        let title: String
        var root: NSView
        var panes: [AgentTerminalPane]
        var active: AgentTerminalPane

        init(_ pane: AgentTerminalPane) {
            title = pane.name
            root = pane
            panes = [pane]
            active = pane
        }
    }

    @MainActor private final class TaskTerminals {
        let id: String
        let workspace: String?
        let directory: URL
        var tabs: [Tab] = []
        var index = 0
        var shown = true

        init(task: AgentTaskRecord, directory: URL) {
            id = task.id
            workspace = task.workspace
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
    private let maximumPanes = 8
    private let tabs = NSPopUpButton(frame: .zero, pullsDown: false)
    private let body = NSView()
    private let path = NSTextField(labelWithString: "")
    private let issue = NSTextField(labelWithString: "")
    private let add = AgentWorkbenchButton(), right = AgentWorkbenchButton(), down = AgentWorkbenchButton()
    private let theme = AgentWorkbenchButton(), hide = AgentWorkbenchButton()
    var onHide: (() -> Void)?
    var isShown: Bool { current?.shown == true && current?.selected != nil }
    private var current: TaskTerminals? { currentID.flatMap { states[$0] } }
    private var paneCount: Int { states.values.reduce(0) { count, state in count + state.tabs.reduce(0) { $0 + $1.panes.count } } }

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
        issue.font = .systemFont(ofSize: 11)
        issue.textColor = .systemRed
        issue.lineBreakMode = .byTruncatingTail
        issue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        issue.isHidden = true
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
        let bar = NSStackView(views: [tabs, path, issue, NSView(), add, right, down, theme, hide])
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
        Self.available(task) && store.organization.archiveID(task.workspace, mode: task.organizationMode) == nil
    }

    func selectTask(_ task: AgentTaskRecord?) {
        guard let store else { return }
        for id in Array(states.keys) {
            guard let state = states[id] else { continue }
            if let record = store.task(id), taskIsAvailable(record, store: store), record.workspace == state.workspace { continue }
            closeState(id)
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
            state.tabs = [Tab(try makePane(for: state))]
            states[id] = state
        }
        render()
    }

    @objc func hidePanel() {
        current?.shown = false
        onHide?()
    }

    func focus() {
        if let pane = current?.selected?.active { window?.makeFirstResponder(pane.surface.view) }
    }

    private func makePane(for state: TaskTerminals) throws -> AgentTerminalPane {
        guard paneCount < maximumPanes, let store, let task = store.task(state.id), taskIsAvailable(task, store: store), task.workspace == state.workspace else {
            throw PetError("任务已变化或终端数量已达上限")
        }
        if let workspace = state.workspace, try AgentFiles(workspace: workspace).root != state.directory {
            throw PetError("项目目录已变化，请重新打开终端")
        }
        let pane = AgentTerminalPane(number: nextNumber, directory: state.directory)
        pane.surface.setDark(dark)
        let operation = pane.id
        let taskID = state.id
        let retention = store.worktreeRetention
        pane.surface.onExit = { [weak pane, weak retention] code in
            retention?.setNativeOperation(operation, taskID: taskID, busy: false)
            pane?.exited(code)
        }
        do { try pane.surface.start(in: state.directory, checkHome: checkHome) }
        catch { throw PetError("终端无法启动。\(error.localizedDescription)") }
        retention.setNativeOperation(operation, taskID: taskID, busy: true)
        nextNumber += 1
        pane.onClose = { [weak self, weak pane] in if let pane { self?.close(pane, taskID: taskID) } }
        pane.surface.onFocus = { [weak self, weak pane] in
            if let pane, let tab = self?.current?.selected, tab.panes.contains(where: { $0 === pane }) {
                tab.active = pane
                tab.panes.forEach { $0.select($0 === pane) }
            }
        }
        return pane
    }

    @objc private func addTab() {
        guard let state = current else { return }
        do {
            state.tabs.append(Tab(try makePane(for: state)))
            state.index = state.tabs.count - 1
            render()
            focus()
        } catch { showIssue(error) }
    }

    @objc private func selectTab() {
        guard let state = current, state.tabs.indices.contains(tabs.indexOfSelectedItem) else { return }
        state.index = tabs.indexOfSelectedItem
        render()
        focus()
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
            let split = NSSplitView(frame: previous.frame)
            split.isVertical = vertical
            split.dividerStyle = .thin
            replace(previous, with: split, in: tab)
            split.addArrangedSubview(previous)
            split.addArrangedSubview(pane)
            split.adjustSubviews()
            split.setPosition(size / 2, ofDividerAt: 0)
            tab.panes.append(pane)
            tab.active = pane
            render()
            focus()
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
        pane.surface.stop()
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
    }

    private func closeState(_ id: String) {
        let state = states.removeValue(forKey: id)
        state?.tabs.flatMap(\.panes).forEach { $0.surface.stop() }
    }

    func stopAll() {
        for id in Array(states.keys) { closeState(id) }
        render()
    }

    @objc private func toggleTheme() {
        dark.toggle()
        let title = dark ? "切换为浅色终端" : "切换为深色终端"
        theme.image = NSImage(systemSymbolName: dark ? "sun.max" : "moon", accessibilityDescription: nil)
        theme.image?.size = NSSize(width: 16, height: 16)
        theme.setAccessibilityLabel(title)
        theme.toolTip = title
        for state in states.values { state.tabs.flatMap(\.panes).forEach { $0.surface.setDark(dark) } }
        focus()
    }

    private func render() {
        let state = current
        tabs.removeAllItems()
        tabs.addItems(withTitles: state?.tabs.map(\.title) ?? [])
        if let state, state.selected != nil { tabs.selectItem(at: state.index) }
        path.stringValue = state?.directory.path ?? ""
        path.toolTip = state?.directory.path
        issue.isHidden = true
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
    }

    private func showIssue(_ error: Error) {
        issue.stringValue = error.localizedDescription
        issue.isHidden = false
    }

    func verificationSnapshot() -> [String: Any] {
        let all = states.values.sorted { $0.id < $1.id }.map { state in
            ["taskID": state.id, "directory": state.directory.path, "shown": state.shown, "tabIndex": state.index,
             "tabs": state.tabs.map { tab in
                 ["active": tab.active.number, "panes": tab.panes.map { pane in
                     ["number": pane.number, "pid": pane.surface.pid, "width": pane.bounds.width, "height": pane.bounds.height,
                      "terminal": pane.surface.textForVerification()]
                 }]
             }] as [String: Any]
        }
        return ["shown": isShown && superview != nil && !isHiddenOrHasHiddenAncestor, "taskID": currentID as Any? ?? NSNull(), "dark": dark, "states": all]
    }
}
