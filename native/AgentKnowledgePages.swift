import AppKit

// Reuse the managers' existing hosting and unsaved-content guards.
@MainActor final class AgentKnowledgePageHost: NSView {
    private struct Entry { let controller: AgentSettingsPageController; let content: NSView }
    private let back = NSButton(title: "返回", target: nil, action: nil), title = NSTextField(labelWithString: "知识中心")
    private let tabs = NSSegmentedControl(labels: ["知识库", "Repo Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let body = NSView(), empty = NSTextField(labelWithString: "暂无内容")
    private var stacks: [String: [Entry]] = [:], root = "library", identity = ""
    private var makeRoot: ((String) -> AgentSettingsPageController?)?
    var currentController: AgentSettingsPageController? { stacks[root]?.last?.controller }
    var controllers: [AgentSettingsPageController] { stacks.values.flatMap { $0.map(\.controller) } }
    var selectedRoot: String { root }
    static var readbackEnabled: Bool { ["--knowledge-review-check", "--knowledge-page-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) }
    var onRootChange: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.isBordered = false; back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        back.target = self; back.action = #selector(goBack)
        back.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true; back.cell?.lineBreakMode = .byTruncatingTail; back.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.target = self; tabs.action = #selector(changeRoot); tabs.setAccessibilityLabel("知识中心类型")
        let header = NSStackView(views: [back, title, NSView(), tabs]); header.spacing = 12
        let column = NSStackView(views: [header, body]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 18
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for child in [header, body] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let width = column.widthAnchor.constraint(equalToConstant: 824); width.priority = .init(499)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: topAnchor, constant: 68), column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24), column.centerXAnchor.constraint(equalTo: centerXAnchor), column.widthAnchor.constraint(lessThanOrEqualToConstant: 824), column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28), column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28), width])
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false; empty.textColor = AgentWorkbenchTheme.secondaryText
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: body.centerXAnchor), empty.centerYAnchor.constraint(equalTo: body.centerYAnchor)])
        updateHeader()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); currentController?.pageDidLayout() }

    @discardableResult func show(root next: String, identity: String, make: @escaping (String) -> AgentSettingsPageController?) -> Bool {
        if root == next, self.identity == identity, stacks[root]?.isEmpty == false { displayCurrent(); return true }
        guard ["library", "wiki"].contains(next), prepareToLeave() else { return false }
        if self.identity != identity { finish(); self.identity = identity }
        makeRoot = make; root = next
        if stacks[root]?.isEmpty != false, let controller = make(next) { return push(controller) }
        displayCurrent(); return true
    }
    @discardableResult func push(_ controller: AgentSettingsPageController) -> Bool {
        guard let host = window, host.attachedSheet == nil, let content = controller.settingsContent(in: host, styled: false) else { return false }
        controller.onSettingsPush = { [weak self] child in _ = self?.push(child) }
        controller.onSettingsClose = { [weak self] in self?.goBack() }
        stacks[root, default: []].append(Entry(controller: controller, content: content)); displayCurrent(); return true
    }
    private func displayCurrent() {
        for view in body.subviews where view !== empty { view.removeFromSuperview() }
        if let entry = stacks[root]?.last {
            body.addSubview(entry.content); entry.content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([entry.content.leadingAnchor.constraint(equalTo: body.leadingAnchor), entry.content.trailingAnchor.constraint(equalTo: body.trailingAnchor), entry.content.topAnchor.constraint(equalTo: body.topAnchor), entry.content.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
            entry.controller.settingsDidAppear()
        }
        updateHeader(); layoutSubtreeIfNeeded(); currentController?.pageDidLayout(); window?.recalculateKeyViewLoop(); onRootChange?(root)
    }
    private func updateHeader() {
        let entries = stacks[root] ?? []; back.isHidden = entries.count < 2
        back.title = entries.count > 1 ? "返回 " + (entries[entries.count - 2].controller.window?.title ?? "知识中心") : "返回"
        title.stringValue = entries.count > 1 ? entries.last?.controller.window?.title ?? "知识中心" : "知识中心"
        tabs.selectedSegment = root == "library" ? 0 : 1; tabs.isHidden = entries.count > 1; empty.isHidden = !entries.isEmpty
    }
    @objc private func goBack() {
        guard let entries = stacks[root], entries.count > 1, entries.last?.controller.canLeaveSettings() == true else { return }
        let entry = stacks[root]!.removeLast(); entry.controller.endSettingsHosting(); displayCurrent()
    }
    @objc private func changeRoot() {
        let next = tabs.selectedSegment == 0 ? "library" : "wiki"
        guard let makeRoot, show(root: next, identity: identity, make: makeRoot) else { updateHeader(); return }
    }
    func prepareToLeave() -> Bool { (stacks[root] ?? []).reversed().allSatisfy { $0.controller.canLeaveSettings() } }
    func finish() {
        for entries in stacks.values { for entry in entries.reversed() { entry.controller.endSettingsHosting() } }
        stacks = [:]; identity = ""; makeRoot = nil
        for view in body.subviews where view !== empty { view.removeFromSuperview() }; updateHeader()
    }
    func checkBack() { if Self.readbackEnabled { goBack() } }
    func checkState() -> [String: Any] {
        guard Self.readbackEnabled else { return [:] }
        var controls: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is NSButton || view is NSSegmentedControl || view is NSSearchField || (view as? NSTextField)?.isEditable == true { controls.append(view); return }
            if view is NSTableView || view is NSTextView { return }
            view.subviews.forEach(visit)
        }
        if let content = currentController?.pageContentView { visit(content) }
        visit(back); visit(tabs)
        let frames = controls.map { view -> [String: Any] in
            let frame = convert(view.bounds, from: view)
            return ["label": view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "", "frame": [frame.minX, frame.minY, frame.width, frame.height], "inside": frame.minX >= -1 && frame.maxX <= bounds.width + 1 && frame.minY >= -1 && frame.maxY <= bounds.height + 1 && frame.width > 0 && frame.height > 0]
        }
        let checks = ["currentPageUsesOwnerWindow": currentController?.pageContentView?.window === window && currentController?.presentingWindow === window,
                      "noFloatingKnowledgeWindows": controllers.allSatisfy { $0.window?.isVisible != true },
                      "allActionsInsideMainContent": !frames.isEmpty && frames.allSatisfy { $0["inside"] as? Bool == true },
                      "rootTabsShownAtCatalog": tabs.isHidden == ((stacks[root]?.count ?? 0) > 1),
                      "readableMainColumn": body.bounds.width >= 500 && body.bounds.width <= 825 && body.bounds.height >= 290]
        return ["root": root, "depth": stacks[root]?.count ?? 0, "controller": currentController.map { String(describing: type(of: $0)) } ?? "", "visible": !isHiddenOrHasHiddenAncestor && window?.isVisible == true, "size": [bounds.width, bounds.height], "bodySize": [body.bounds.width, body.bounds.height], "backVisible": !back.isHidden, "controls": frames, "checks": checks]
    }
}

@MainActor final class AgentKnowledgeSourcePage: AgentSettingsPageController {
    private let file: URL?
    init(title: String, text: String, file: URL? = nil) {
        self.file = file
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface), view = NSTextView(), scroll = NSScrollView()
        view.isEditable = false; view.isRichText = false; view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width: 12, height: 12)
        view.string = text; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textColor = .labelColor; view.drawsBackground = false; view.setAccessibilityLabel("知识来源正文")
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        let open = NSButton(title: "在外部打开", target: self, action: #selector(openFile)); open.isHidden = file == nil
        let actions = NSStackView(views: [NSView(), open]), column = NSStackView(views: [scroll, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        window.contentView = content; content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for child in [scroll, actions] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor), column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func openFile() { if let file { NSWorkspace.shared.open(file) } }
}
