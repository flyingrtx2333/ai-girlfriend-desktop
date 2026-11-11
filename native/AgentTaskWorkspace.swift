import AppKit

@MainActor final class AgentWorkspacePageView: AgentThemeView {
    var onResize: (() -> Void)?
    private var previousSize: NSSize?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if previousSize != bounds.size { needsUpdateConstraints = true }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); needsUpdateConstraints = true }
    override func updateConstraints() {
        if previousSize != bounds.size { previousSize = bounds.size; onResize?() }
        super.updateConstraints()
    }
}

// Each task owns its tabs and child pages. Cached editors stay intact until
// their tab is closed, when the existing unsaved-content guards apply.
@MainActor final class AgentTaskWorkspace: NSView {
    enum Root: Hashable {
        case review, records, context, document(String), canvas(String)
        var title: String {
            switch self { case .review: return "审阅"; case .records: return "记录"; case .context: return "任务详情"; case .document(let path): return URL(fileURLWithPath: path).lastPathComponent; case .canvas: return "画布" }
        }
        var key: String {
            switch self { case .review: return "review"; case .records: return "records"; case .context: return "context"; case .document(let path): return "document:" + path; case .canvas(let id): return "canvas:" + id }
        }
    }
    private struct Entry { let controller: AgentSettingsPageController; let content: NSView }
    private let back = NSButton(), expand = NSButton(), hide = NSButton(), add = NSButton()
    private let title = NSTextField(labelWithString: ""), body = NSView(), tabs = NSStackView(), tabScroll = NSScrollView(), breadcrumb = NSStackView()
    private var stacks: [String: [Root: [Entry]]] = [:], orders: [String: [Root]] = [:], selected: [String: Root] = [:]
    private var opened = Set<String>(), expandedTasks = Set<String>(), tabSignature = "", headerFull: Bool?, closing = false
    private var breadcrumbHeight: NSLayoutConstraint!, tabViews: [(Root, AgentThemeView, NSButton, NSButton, NSLayoutConstraint, NSLayoutConstraint)] = []
    private(set) var taskID: String?
    var onLayoutChange: (() -> Void)?
    var onOpenRoot: ((Root) -> Void)?, onOpenDocument: (() -> Void)?, onOpenTerminal: (() -> Void)?
    var requested: Bool { taskID.map(opened.contains) == true }
    var expanded: Bool { taskID.map(expandedTasks.contains) == true }
    var selectedRoot: Root { taskID.flatMap { selected[$0] } ?? .review }
    private var entries: [Entry] { taskID.flatMap { stacks[$0]?[selectedRoot] } ?? [] }
    var currentController: AgentSettingsPageController? { entries.last?.controller }
    var controllers: [AgentSettingsPageController] { stacks.values.flatMap { $0.values.flatMap { $0.map(\.controller) } } }
    static var readbackEnabled: Bool { ["--worktree-workspace-check", "--artifact-workspace-check", "--task-workspace-check", "--git-workspace-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, symbol, label, action) in [(back, "chevron.left", "返回", #selector(goBack)), (expand, "arrow.up.left.and.arrow.down.right", "放大工作区", #selector(toggleExpanded)), (hide, "xmark", "收起工作区", #selector(hideWorkspace)), (add, "plus", "添加工作区标签页", #selector(openMenu))] {
            button.isBordered = false; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.setAccessibilityLabel(label); button.toolTip = label; button.target = self; button.action = action
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true; button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.orientation = .horizontal; tabs.spacing = 2; tabs.alignment = .centerY
        tabScroll.documentView = tabs; tabScroll.hasHorizontalScroller = true; tabScroll.scrollerStyle = .overlay; tabScroll.drawsBackground = false; tabScroll.setAccessibilityLabel("任务工作区标签页")
        tabScroll.heightAnchor.constraint(equalToConstant: 32).isActive = true; tabScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [tabScroll, add, expand, hide]); header.spacing = 6
        for view in [back, title, NSView()] { breadcrumb.addArrangedSubview(view) }; breadcrumb.spacing = 8
        let rule = AgentThemeView(fill: AgentWorkbenchTheme.line)
        for view in [header, rule, breadcrumb, body] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        breadcrumbHeight = breadcrumb.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 43),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor), rule.topAnchor.constraint(equalTo: header.bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            breadcrumb.leadingAnchor.constraint(equalTo: header.leadingAnchor), breadcrumb.trailingAnchor.constraint(equalTo: header.trailingAnchor), breadcrumb.topAnchor.constraint(equalTo: rule.bottomAnchor), breadcrumbHeight,
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        breadcrumb.isHidden = true; isHidden = true; updateHeader(full: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); layoutTabs() }
    private func layoutTabs() {
        let width = tabViews.reduce(CGFloat(0)) { $0 + $1.1.fittingSize.width } + CGFloat(max(0, tabViews.count - 1)) * tabs.spacing
        let size = NSSize(width: max(tabScroll.contentSize.width, width), height: tabScroll.contentSize.height)
        if tabs.frame.size != size { tabs.setFrameSize(size) }; tabs.layoutSubtreeIfNeeded()
    }
    @discardableResult func selectTask(_ id: String) -> Bool {
        guard taskID != id else { return true }; guard prepareToNavigate() else { return false }
        taskID = id; displayCurrent(); return true
    }
    @discardableResult func show(taskID id: String, root: Root = .review, make: () -> AgentSettingsPageController) -> Bool {
        guard selectTask(id), prepareToNavigate() else { return false }; selected[id] = root; opened.insert(id)
        if stacks[id]?[root]?.isEmpty != false { orders[id, default: []].append(root); push(make(), taskID: id, root: root) }
        else { displayCurrent() }
        onLayoutChange?(); return true
    }
    func rootController(_ root: Root) -> AgentSettingsPageController? { taskID.flatMap { stacks[$0]?[root]?.first?.controller } }
    private func push(_ controller: AgentSettingsPageController, taskID id: String, root: Root) {
        if taskID == id, selectedRoot == root, !prepareToNavigate() { return }
        guard let window, window.attachedSheet == nil, let content = controller.settingsContent(in: window, styled: false) else { return }
        controller.onSettingsPush = { [weak self] child in self?.push(child, taskID: id, root: root) }; controller.onSettingsClose = { [weak self] in self?.pop(taskID: id, root: root) }
        (controller as? AgentRecordWindow)?.onWorkspaceChange = { [weak self] in self?.updateTabs() }
        (controller as? AgentOfficeWindow)?.onWorkspaceChange = { [weak self] in self?.updateTabs() }
        (controller as? AgentCanvasWindow)?.onWorkspaceChange = { [weak self] in self?.updateTabs() }
        stacks[id, default: [:]][root, default: []].append(Entry(controller: controller, content: content))
        if taskID == id, selectedRoot == root { displayCurrent() }
    }
    private func displayCurrent() {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: body) { window?.makeFirstResponder(nil) }
        body.subviews.forEach { $0.removeFromSuperview() }
        if let entry = entries.last {
            body.addSubview(entry.content); entry.content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([entry.content.leadingAnchor.constraint(equalTo: body.leadingAnchor), entry.content.trailingAnchor.constraint(equalTo: body.trailingAnchor), entry.content.topAnchor.constraint(equalTo: body.topAnchor), entry.content.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
            entry.controller.settingsDidAppear()
        }
        updateTabs(); updateHeader(full: headerFull ?? expanded); needsLayout = true; window?.recalculateKeyViewLoop()
    }
    private func updateTabs() {
        let roots = taskID.flatMap { orders[$0] } ?? [], signature = (taskID ?? "") + roots.map(\.key).joined(separator: "\n")
        if tabSignature != signature {
            tabs.arrangedSubviews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }; tabViews = []; tabSignature = signature
            for (index, root) in roots.enumerated() {
                let group = AgentThemeView(fill: .clear), button = NSButton(title: root.title, target: self, action: #selector(selectTab)), close = NSButton()
                button.isBordered = false; button.font = .systemFont(ofSize: 12, weight: .medium); button.cell?.lineBreakMode = .byTruncatingMiddle; button.tag = index; button.setAccessibilityLabel(root.title + " 标签页")
                close.isBordered = false; close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil); close.imageScaling = .scaleProportionallyDown; close.setAccessibilityLabel("关闭 " + root.title + " 标签页"); close.target = self; close.action = #selector(closeTab); close.tag = index
                group.wantsLayer = true; group.layer?.cornerRadius = 6
                for view in [button, close] { group.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
                let labelWidth = min(154, max(48, ceil((root.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 12))
                let groupWidth = group.widthAnchor.constraint(equalToConstant: labelWidth + 26), buttonWidth = button.widthAnchor.constraint(equalToConstant: labelWidth)
                NSLayoutConstraint.activate([groupWidth, group.heightAnchor.constraint(equalToConstant: 28), button.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 4), buttonWidth, button.centerYAnchor.constraint(equalTo: group.centerYAnchor), close.leadingAnchor.constraint(equalTo: button.trailingAnchor), close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18), close.centerYAnchor.constraint(equalTo: group.centerYAnchor)])
                tabs.addArrangedSubview(group); tabViews.append((root, group, button, close, groupWidth, buttonWidth))
            }
        }
        for (root, group, button, close, groupWidth, buttonWidth) in tabViews {
            let page = rootController(root), dirty = (page as? AgentRecordWindow)?.workspaceHasUnsavedChanges == true || (page as? AgentOfficeWindow)?.dirty == true || (page as? AgentCanvasWindow)?.workspaceHasUnsavedChanges == true
            let label: String; if case .canvas = root { label = page?.window?.title ?? root.title } else { label = root.title }
            group.fill = root == selectedRoot ? AgentWorkbenchTheme.navigationSelection : .clear; button.state = root == selectedRoot ? .on : .off; button.title = (dirty ? "• " : "") + label
            buttonWidth.constant = min(154, max(48, ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width) + 12)); groupWidth.constant = buttonWidth.constant + 26
            close.setAccessibilityLabel("关闭 " + label + " 标签页")
            button.setAccessibilityLabel(label + (dirty ? " 未保存" : "") + " 标签页"); if case .document(let path) = root { button.toolTip = path }
        }
        layoutTabs(); if let group = tabViews.first(where: { $0.0 == selectedRoot })?.1 { tabs.scrollToVisible(group.frame) }
    }
    func updateHeader(full: Bool, canSplit: Bool? = nil) {
        back.isHidden = entries.count < 2; breadcrumbHeight.constant = back.isHidden ? 0 : 34; breadcrumb.isHidden = back.isHidden
        let previous = entries.count > 2 ? entries[entries.count - 2].controller.window?.title ?? selectedRoot.title : selectedRoot == .review ? "Git 审阅" : selectedRoot.title
        back.setAccessibilityLabel("返回 " + previous); back.toolTip = "返回 " + previous
        let text = entries.count > 1 ? entries.last?.controller.window?.title ?? selectedRoot.title : ""; if title.stringValue != text { title.stringValue = text }
        let hideLabel = selectedRoot == .review ? "收起 Git 工作区" : "收起工作区"; hide.setAccessibilityLabel(hideLabel); hide.toolTip = hideLabel
        if let canSplit { expand.isHidden = !canSplit }; guard headerFull != full else { return }; headerFull = full
        let label = full ? "还原工作区" : "放大工作区"; expand.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil); expand.setAccessibilityLabel(label); expand.toolTip = label
    }
    @objc private func selectTab(_ sender: NSButton) {
        guard let id = taskID, let roots = orders[id], roots.indices.contains(sender.tag), prepareToNavigate() else { return }
        selected[id] = roots[sender.tag]; displayCurrent(); onLayoutChange?()
    }
    @objc private func closeTab(_ sender: NSButton) {
        guard let id = taskID, let roots = orders[id], roots.indices.contains(sender.tag), prepareToNavigate() else { return }
        let root = roots[sender.tag]; selected[id] = root; displayCurrent()
        requestClose(taskID: id, root: root)
    }
    private func requestClose(taskID id: String, root: Root) {
        guard !closing else { return }; closing = true
        Task { @MainActor [weak self] in
            guard let self else { return }; defer { closing = false }
            for entry in (stacks[id]?[root] ?? []).reversed() { guard await entry.controller.prepareForWorkspaceClose() else { return } }
            removeRoot(taskID: id, root: root)
        }
    }
    private func removeRoot(taskID id: String, root: Root) {
        let old = stacks[id]?.removeValue(forKey: root) ?? []; old.reversed().forEach { $0.controller.endSettingsHosting() }; orders[id]?.removeAll { $0 == root }
        if selected[id] == root { selected[id] = orders[id]?.last }
        if orders[id]?.isEmpty != false { selected[id] = nil; opened.remove(id) }
        if taskID == id { displayCurrent(); onLayoutChange?() }
    }
    @objc private func openMenu() {
        let menu = NSMenu()
        for root in [Root.review, .records, .context] {
            let item = NSMenuItem(title: "打开" + root.title, action: #selector(openRoot(_:)), keyEquivalent: ""); item.target = self; item.representedObject = root; item.state = taskID.flatMap { stacks[$0]?[root] } == nil ? .off : .on; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (label, action) in [("打开工作区文件…", #selector(openDocument)), ("打开终端", #selector(openTerminal))] { let item = NSMenuItem(title: label, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.maxY), in: add)
    }
    @objc private func openRoot(_ sender: NSMenuItem) { if let root = sender.representedObject as? Root { onOpenRoot?(root) } }
    @objc private func openDocument() { onOpenDocument?() }
    @objc private func openTerminal() { onOpenTerminal?() }
    @objc private func goBack() { if let taskID { pop(taskID: taskID, root: selectedRoot) } }
    private func pop(taskID id: String, root: Root) {
        if (stacks[id]?[root]?.first?.controller as? AgentOfficeWindow)?.workspaceIsClosed == true || (stacks[id]?[root]?.first?.controller as? AgentCanvasWindow)?.workspaceIsClosed == true { removeRoot(taskID: id, root: root); return }
        if stacks[id]?[root]?.count == 1 {
            requestClose(taskID: id, root: root); return
        }
        guard (stacks[id]?[root]?.count ?? 0) > 1, stacks[id]?[root]?.last?.controller.canLeaveSettings() == true else { return }
        let entry = stacks[id]![root]!.removeLast(); entry.controller.endSettingsHosting(); if taskID == id, selectedRoot == root { displayCurrent() }
    }
    func prepareToNavigate() -> Bool {
        guard !closing, window?.attachedSheet == nil else { return false }
        for entry in entries {
            if let record = entry.controller as? AgentRecordWindow, !record.prepareWorkspaceNavigation() { return false }
            if let comparison = entry.controller as? AgentFileConflictWindow, !comparison.canNavigateWorkspace { return false }
            if let office = entry.controller as? AgentOfficeWindow, !office.prepareWorkspaceNavigation() { return false }
            if let canvas = entry.controller as? AgentCanvasWindow, !canvas.prepareWorkspaceNavigation() { return false }
            if let creation = entry.controller as? AgentWorktreeCreationWindow, !creation.prepareWorkspaceNavigation() { return false }
            if let manager = entry.controller as? AgentWorktreeWindow, !manager.prepareWorkspaceNavigation() { return false }
        }; return true
    }
    @objc private func hideWorkspace() { guard let taskID, prepareToNavigate() else { return }; opened.remove(taskID); onLayoutChange?() }
    func hideForNavigation() { hideWorkspace() }
    @objc private func toggleExpanded() { guard let taskID else { return }; if expandedTasks.contains(taskID) { expandedTasks.remove(taskID) } else { expandedTasks.insert(taskID) }; onLayoutChange?() }
    func canFinish() async -> Bool {
        guard !closing else { return false }; closing = true; defer { closing = false }
        for controller in controllers.reversed() { if !(await controller.prepareForWorkspaceClose()) { return false } }; return true
    }
    func requireDeletionAllowed(_ ids: Set<String>) throws {
        guard !closing else { throw PetError("请先完成工作区关闭操作") }
        for id in ids { for entries in (stacks[id] ?? [:]).values { for entry in entries {
            try (entry.controller as? AgentRecordWindow)?.requireDeletionAllowed(ids)
            if (entry.controller as? AgentFileConflictWindow)?.canNavigateWorkspace == false { throw PetError("请先完成文件比较中的操作") }
            if (entry.controller as? AgentGitWindow)?.hasPendingChanges == true || (entry.controller as? AgentGitPushWindow)?.hasPendingOperation == true || (entry.controller as? AgentDependencyWindow)?.hasPendingOperation == true || (entry.controller as? AgentGitRemotePage)?.hasPendingChanges == true { throw PetError("请先完成 Git 操作或处理提交草稿") }
            if (entry.controller as? AgentWorktreeCreationWindow)?.hasPendingChanges == true || (entry.controller as? AgentWorktreeWindow)?.hasPendingOperation == true { throw PetError("请先完成工作树操作或处理创建配置") }
        } } }
    }
    func finish(tasks ids: Set<String>? = nil) {
        for id in ids ?? Set(stacks.keys) {
            for entries in (stacks.removeValue(forKey: id) ?? [:]).values { entries.reversed().forEach { $0.controller.endSettingsHosting() } }
            orders[id] = nil; selected[id] = nil; opened.remove(id); expandedTasks.remove(id)
        }; displayCurrent(); onLayoutChange?()
    }
    func checkBack() { if Self.readbackEnabled { goBack() } }
    func checkExpand() { if Self.readbackEnabled { toggleExpanded() } }
    func checkHide() { if Self.readbackEnabled { hideWorkspace() } }
    func checkSelect(_ root: Root) { if Self.readbackEnabled, let button = tabViews.first(where: { $0.0 == root })?.2 { selectTab(button) } }
    func checkClose(_ root: Root) { if Self.readbackEnabled, let button = tabViews.first(where: { $0.0 == root })?.3 { closeTab(button) } }
    func checkState() -> [String: Any] {
        guard Self.readbackEnabled else { return [:] }
        let attached = currentController?.pageContentView?.window === window && currentController?.presentingWindow === window
        let checks = ["workspaceUsesTaskWindow": attached, "noFloatingGitPages": controllers.allSatisfy { $0.window?.isVisible != true }, "workspaceHasUsableWidth": bounds.width >= 450, "workspaceHasUsableHeight": body.bounds.height >= 300]
        return ["taskID": taskID ?? "", "root": selectedRoot.key, "roots": taskID.flatMap { orders[$0]?.map(\.key) } ?? [], "tabLabels": tabViews.map { $0.2.title }, "requested": requested, "expanded": expanded, "closing": closing, "depth": entries.count, "controller": currentController.map { String(describing: type(of: $0)) } ?? "", "visible": !isHiddenOrHasHiddenAncestor, "size": [bounds.width, bounds.height], "expandVisible": !expand.isHidden, "expandLabel": expand.accessibilityLabel() ?? "", "backLabel": back.accessibilityLabel() ?? "", "checks": checks]
    }
}
