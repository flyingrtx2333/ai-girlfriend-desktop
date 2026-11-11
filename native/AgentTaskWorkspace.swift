import AppKit

// Keep each task's review, navigation and unsent commit text alive when the
// workspace is hidden or another task is selected. Closing the owner still
// uses the existing controllers' close guards and cancellation paths.
@MainActor final class AgentTaskWorkspace: NSView {
    private struct Entry { let controller: AgentSettingsPageController; let content: NSView }
    private let back = NSButton(), expand = NSButton(), hide = NSButton()
    private let title = NSTextField(labelWithString: "审阅"), body = NSView()
    private var stacks: [String: [Entry]] = [:], opened = Set<String>(), expandedTasks = Set<String>()
    private var headerFull: Bool?
    private(set) var taskID: String?
    var onLayoutChange: (() -> Void)?
    var requested: Bool { taskID.map(opened.contains) == true }
    var expanded: Bool { taskID.map(expandedTasks.contains) == true }
    var currentController: AgentSettingsPageController? { taskID.flatMap { stacks[$0]?.last?.controller } }
    var controllers: [AgentSettingsPageController] { stacks.values.flatMap { $0.map(\.controller) } }
    static var readbackEnabled: Bool { ["--git-workspace-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, symbol, label, action) in [(back, "chevron.left", "返回 Git 审阅", #selector(goBack)), (expand, "arrow.up.left.and.arrow.down.right", "放大工作区", #selector(toggleExpanded)), (hide, "xmark", "收起 Git 工作区", #selector(hideWorkspace))] {
            button.isBordered = false; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.setAccessibilityLabel(label); button.toolTip = label; button.target = self; button.action = action
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true; button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [back, title, NSView(), expand, hide]); header.spacing = 8
        let rule = AgentThemeView(fill: AgentWorkbenchTheme.line)
        for view in [header, rule, body] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 43),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor), rule.topAnchor.constraint(equalTo: header.bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: rule.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true; updateHeader(full: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); currentController?.pageDidLayout() }

    func selectTask(_ id: String) {
        guard taskID != id else { return }
        currentController?.settingsWillLeave(); taskID = id; displayCurrent()
    }
    func show(taskID: String, make: () -> AgentGitWindow) {
        selectTask(taskID); opened.insert(taskID)
        if stacks[taskID]?.isEmpty != false { push(make(), taskID: taskID) }
        else { displayCurrent() }
        onLayoutChange?()
    }
    private func push(_ controller: AgentSettingsPageController, taskID id: String) {
        guard let window, window.attachedSheet == nil, let content = controller.settingsContent(in: window, styled: false) else { return }
        stacks[id]?.last?.controller.settingsWillLeave()
        controller.onSettingsPush = { [weak self] child in self?.push(child, taskID: id) }
        controller.onSettingsClose = { [weak self] in self?.pop(taskID: id) }
        stacks[id, default: []].append(Entry(controller: controller, content: content))
        if taskID == id { displayCurrent() }
    }
    private func displayCurrent() {
        body.subviews.forEach { $0.removeFromSuperview() }
        if let taskID, let entry = stacks[taskID]?.last {
            body.addSubview(entry.content); entry.content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([entry.content.leadingAnchor.constraint(equalTo: body.leadingAnchor), entry.content.trailingAnchor.constraint(equalTo: body.trailingAnchor), entry.content.topAnchor.constraint(equalTo: body.topAnchor), entry.content.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
            entry.controller.settingsDidAppear()
        }
        updateHeader(full: headerFull ?? expanded); needsLayout = true; window?.recalculateKeyViewLoop()
    }
    func updateHeader(full: Bool, canSplit: Bool? = nil) {
        let entries = taskID.flatMap { stacks[$0] } ?? []
        back.isHidden = entries.count < 2
        let previous = entries.count > 2 ? entries[entries.count - 2].controller.window?.title ?? "Git" : "Git 审阅"
        back.setAccessibilityLabel("返回 " + previous); back.toolTip = "返回 " + previous
        if let canSplit { expand.isHidden = !canSplit }
        let text = entries.count > 1 ? entries.last?.controller.window?.title ?? "Git" : "审阅"
        if title.stringValue != text { title.stringValue = text }
        guard headerFull != full else { return }; headerFull = full
        let label = full ? "还原工作区" : "放大工作区"
        expand.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        expand.setAccessibilityLabel(label); expand.toolTip = label
    }
    @objc private func goBack() {
        if let taskID { pop(taskID: taskID) }
    }
    private func pop(taskID id: String) {
        guard (stacks[id]?.count ?? 0) > 1, stacks[id]?.last?.controller.canLeaveSettings() == true else { return }
        let entry = stacks[id]!.removeLast(); entry.controller.endSettingsHosting()
        if taskID == id { displayCurrent() }
    }
    @objc private func hideWorkspace() {
        guard let taskID, window?.attachedSheet == nil else { return }
        opened.remove(taskID); currentController?.settingsWillLeave(); onLayoutChange?()
    }
    func hideForNavigation() { hideWorkspace() }
    @objc private func toggleExpanded() {
        guard let taskID else { return }
        if expandedTasks.contains(taskID) { expandedTasks.remove(taskID) } else { expandedTasks.insert(taskID) }
        onLayoutChange?()
    }
    func canFinish() -> Bool { controllers.reversed().allSatisfy { $0.canLeaveSettings() } }
    func requireDeletionAllowed(_ ids: Set<String>) throws {
        for id in ids {
            for entry in stacks[id] ?? [] {
                if (entry.controller as? AgentGitWindow)?.hasPendingChanges == true || (entry.controller as? AgentGitPushWindow)?.hasPendingOperation == true || (entry.controller as? AgentDependencyWindow)?.hasPendingOperation == true || (entry.controller as? AgentGitRemotePage)?.hasPendingChanges == true {
                    throw PetError("请先完成 Git 操作或处理提交草稿")
                }
            }
        }
    }
    func finish(tasks ids: Set<String>? = nil) {
        for id in ids ?? Set(stacks.keys) {
            for entry in (stacks.removeValue(forKey: id) ?? []).reversed() { entry.controller.endSettingsHosting() }
            opened.remove(id); expandedTasks.remove(id)
        }
        displayCurrent(); onLayoutChange?()
    }
    func checkBack() { if Self.readbackEnabled { goBack() } }
    func checkExpand() { if Self.readbackEnabled { toggleExpanded() } }
    func checkHide() { if Self.readbackEnabled { hideWorkspace() } }
    func checkState() -> [String: Any] {
        guard Self.readbackEnabled else { return [:] }
        let attached = currentController?.pageContentView?.window === window && currentController?.presentingWindow === window
        let checks = ["workspaceUsesTaskWindow": attached, "noFloatingGitPages": controllers.allSatisfy { $0.window?.isVisible != true }, "workspaceHasUsableWidth": bounds.width >= 450, "workspaceHasUsableHeight": body.bounds.height >= 300]
        return ["taskID": taskID ?? "", "requested": requested, "expanded": expanded, "depth": taskID.flatMap { stacks[$0]?.count } ?? 0, "controller": currentController.map { String(describing: type(of: $0)) } ?? "", "visible": !isHiddenOrHasHiddenAncestor, "size": [bounds.width, bounds.height], "expandVisible": !expand.isHidden, "expandLabel": expand.accessibilityLabel() ?? "", "backLabel": back.accessibilityLabel() ?? "", "checks": checks]
    }
}
