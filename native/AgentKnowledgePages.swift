import AppKit

// Reuse the managers' existing hosting and unsaved-content guards.
@MainActor final class AgentKnowledgePageHost: NSView {
    private struct Entry { let controller: AgentSettingsPageController; let content: NSView }
    private let back = AgentWorkbenchButton(), title = NSTextField(labelWithString: "知识中心")
    private let tabs = NSSegmentedControl(labels: ["知识库", "Repo Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let body = NSView(), empty = NSTextField(labelWithString: "暂无内容")
    private var stacks: [String: [Entry]] = [:], root = "library", identity = ""
    private var makeRoot: ((String) -> AgentSettingsPageController?)?
    private var recoveryRevision = 0
    var currentController: AgentSettingsPageController? { stacks[root]?.last?.controller }
    var controllers: [AgentSettingsPageController] { stacks.values.flatMap { $0.map(\.controller) } }
    var selectedRoot: String { root }
    var recoveryReaders: [AgentRecordWindow] { (stacks["wiki"] ?? []).compactMap { $0.controller as? AgentRecordWindow }.filter(\.isKnowledgeWikiReader) }
    var recoveryEditors: [AgentSettingsPageController] {
        (stacks["wiki"] ?? []).map(\.controller).filter { ($0 as? AgentRecordWindow)?.isKnowledgeWikiReader == true || $0 is AgentKnowledgeCardWindow || $0 is AgentKnowledgeWindow } + (stacks["library"] ?? []).map(\.controller).filter { $0 is AgentKnowledgeLibraryWindow }
    }
    static var readbackEnabled: Bool { ["--knowledge-editor-recovery-check", "--knowledge-editor-recovery-ui", "--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui", "--knowledge-source-recovery-check", "--knowledge-source-recovery-ui", "--knowledge-video-check", "--wiki-lifecycle-check", "--knowledge-review-check", "--knowledge-page-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) }
    var onRootChange: ((String) -> Void)?
    var onRecoveryChange: (() -> Void)?
    private func recoveryChanged() { recoveryRevision &+= 1; onRecoveryChange?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        AgentWorkbenchTheme.toolbar(back, title: "返回", symbol: "arrow.left")
        back.target = self; back.action = #selector(goBack)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.target = self; tabs.action = #selector(changeRoot); tabs.setAccessibilityLabel("知识中心类型")
        let header = NSStackView(views: [back, title, NSView(), tabs]); header.spacing = 8; header.alignment = .centerY
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
        if root == next, self.identity == identity, let entry = stacks[root]?.last {
            if !(entry.controller is AgentRepoWikiWindow && entry.controller.isPageVisible) { displayCurrent() }
            return true
        }
        guard ["library", "wiki"].contains(next), prepareToLeave() else { return false }
        if self.identity != identity { finish(); self.identity = identity }
        makeRoot = make; root = next
        if stacks[root]?.isEmpty != false, let controller = make(next) { return push(controller) }
        displayCurrent(); recoveryChanged(); return true
    }
    @discardableResult func push(_ controller: AgentSettingsPageController) -> Bool {
        push(controller, root: root)
    }
    @discardableResult private func push(_ controller: AgentSettingsPageController, root ownerRoot: String) -> Bool {
        guard let host = window, !host.hasBlockingDialog, let content = controller.settingsContent(in: host, styled: false) else { return false }
        controller.onSettingsPush = { [weak self] child in _ = self?.push(child, root: ownerRoot) }
        controller.onSettingsClose = { [weak self] in self?.goBack() }
        let changed: () -> Void = { [weak self] in self?.updateHeader(); self?.recoveryChanged() }
        (controller as? AgentRecordWindow)?.onWorkspaceChange = changed
        (controller as? AgentKnowledgeCardWindow)?.onWorkspaceChange = changed
        (controller as? AgentKnowledgeWindow)?.onWorkspaceChange = changed
        (controller as? AgentKnowledgeLibraryWindow)?.onWorkspaceChange = changed
        (controller as? AgentRepoWikiWindow)?.onWorkspaceChange = { [weak self] in self?.recoveryChanged() }
        if ownerRoot == "library", let video = controller as? AgentVideoWindow { video.onWorkspaceChange = changed }
        stacks[ownerRoot, default: []].append(Entry(controller: controller, content: content))
        if ownerRoot == root { displayCurrent() }; recoveryChanged(); return true
    }
    private func displayCurrent() {
        for view in body.subviews where view !== empty { view.removeFromSuperview() }
        if let entry = stacks[root]?.last {
            body.addSubview(entry.content); entry.content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([entry.content.leadingAnchor.constraint(equalTo: body.leadingAnchor), entry.content.trailingAnchor.constraint(equalTo: body.trailingAnchor), entry.content.topAnchor.constraint(equalTo: body.topAnchor), entry.content.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
            entry.controller.settingsDidAppear()
        }
        updateHeader(); layoutSubtreeIfNeeded(); currentController?.pageDidLayout(); window?.recalculateKeyViewLoop(); focusCurrentPage(); onRootChange?(root)
    }
    func focusCurrentPage() {
        guard !isHiddenOrHasHiddenAncestor, let window, window.isVisible, let content = currentController?.pageContentView else { return }
        if let focused = window.firstResponder as? NSView, focused.isDescendant(of: content), focused.canBecomeKeyView { return }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            func ownsEditor(_ view: NSView) -> Bool {
                guard !view.isHidden else { return false }
                if let field = view as? NSTextField, field.currentEditor() === editor { return field.canBecomeKeyView }
                return view.subviews.contains(where: ownsEditor)
            }
            if ownsEditor(content) { return }
        }
        func firstKeyView(_ view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            if view.canBecomeKeyView { return view }
            return view.subviews.lazy.compactMap(firstKeyView).first
        }
        let initial = currentController?.window?.initialFirstResponder as? NSView
        let target = initial.flatMap { $0.isDescendant(of: content) && $0.canBecomeKeyView ? $0 : nil } ?? firstKeyView(content)
        if let target { window.makeFirstResponder(target) }
    }
    private func updateHeader() {
        let entries = stacks[root] ?? []; back.isHidden = entries.count < 2
        let destination = entries.count > 1 ? "返回 " + (entries[entries.count - 2].controller.window?.title ?? "知识中心") : "返回"
        back.setAccessibilityLabel(destination); back.toolTip = destination
        title.stringValue = entries.count > 1 ? entries.last?.controller.window?.title ?? "知识中心" : "知识中心"
        tabs.selectedSegment = root == "library" ? 0 : 1; tabs.isHidden = entries.count > 1; empty.isHidden = !entries.isEmpty
    }
    @objc private func goBack() {
        guard let entries = stacks[root], entries.count > 1, entries.last?.controller.canLeaveSettings() == true else { return }
        let entry = stacks[root]!.removeLast(); entry.controller.endSettingsHosting(); displayCurrent(); recoveryChanged()
        if root == "library", entry.controller is AgentVideoWindow { (currentController as? AgentKnowledgeLibraryWindow)?.focusLocalVideoPicker() }
    }
    @objc private func changeRoot() {
        let next = tabs.selectedSegment == 0 ? "library" : "wiki"
        guard let makeRoot, show(root: next, identity: identity, make: makeRoot) else { updateHeader(); return }
    }
    func prepareToLeave(preserving: Set<ObjectIdentifier> = []) -> Bool {
        for entry in (stacks[root] ?? []).reversed() {
            if let reader = entry.controller as? AgentRecordWindow, preserving.contains(ObjectIdentifier(reader)) {
                guard reader.prepareWorkspaceNavigation() else { return false }
            } else if let cards = entry.controller as? AgentKnowledgeCardWindow, preserving.contains(ObjectIdentifier(cards)) {
                guard cards.prepareWorkspaceNavigation() else { return false }
            } else if let index = entry.controller as? AgentKnowledgeWindow, preserving.contains(ObjectIdentifier(index)) {
                guard index.prepareWorkspaceNavigation() else { return false }
            } else if let plan = entry.controller as? AgentWikiPlanWindow, preserving.contains(ObjectIdentifier(plan)) {
                guard plan.prepareWorkspaceNavigation() else { return false }
            } else if let library = entry.controller as? AgentKnowledgeLibraryWindow, preserving.contains(ObjectIdentifier(library)) {
                guard library.prepareWorkspaceNavigation() else { return false }
            } else if !entry.controller.canLeaveSettings() { return false }
        }
        return true
    }
    func captureWorkspaceRecovery(active: Bool) async throws -> AgentWorkspaceRecovery.Knowledge? {
        while true {
            let revision = recoveryRevision, identity = identity, root = root
            let catalog = (stacks["wiki"]?.first?.controller as? AgentRepoWikiWindow)?.captureWorkspaceRecovery()
            var pages: [AgentWorkspaceRecovery.Page] = []
            var library: AgentWorkspaceRecovery.KnowledgeLibrary?
            for reader in recoveryEditors {
                if let reader = reader as? AgentRecordWindow { pages.append(try await reader.captureWorkspaceRecovery()) }
                else if let reader = reader as? AgentKnowledgeCardWindow, let page = try reader.captureWorkspaceRecovery() { pages.append(page) }
                else if let reader = reader as? AgentKnowledgeWindow, let page = try reader.captureWorkspaceRecovery() { pages.append(page) }
                else if let reader = reader as? AgentKnowledgeLibraryWindow { library = try reader.captureWorkspaceRecovery() }
            }
            var libraryVideo: AgentWorkspaceRecovery.KnowledgeLibraryVideo?
            if let catalog = stacks["library"]?.first?.controller as? AgentKnowledgeLibraryWindow,
               let video = stacks["library"]?.last?.controller as? AgentVideoWindow,
               let position = try await video.captureWorkspaceRecovery(includingHosted: true) {
                libraryVideo = catalog.captureLocalVideo(position)
            }
            guard revision == recoveryRevision else { continue }
            let visibleReader = currentController is AgentRecordWindow || currentController is AgentMarkdownSourceWindow || currentController is AgentVideoWindow || currentController is AgentKnowledgeCardWindow || currentController is AgentKnowledgeWindow || currentController is AgentKnowledgeSourcePage || currentController is AgentWikiPlanWindow ||
                (currentController as? AgentKnowledgeReviewWindow)?.isRecoverableVersionReview == true
            let visibleCatalog = currentController is AgentRepoWikiWindow && catalog != nil || currentController is AgentKnowledgeLibraryWindow && library != nil
            let value = AgentWorkspaceRecovery.Knowledge(identity: identity, root: root, active: active && (visibleReader || visibleCatalog), readers: pages, library: library, wikiCatalog: catalog, libraryVideo: libraryVideo)
            return value.hasContent ? value : nil
        }
    }
    func restoreWorkspaceRecovery(_ value: AgentWorkspaceRecovery.Knowledge,
                                  make: @escaping (String) -> AgentSettingsPageController?,
                                  reader: (AgentWorkspaceRecovery.Page) throws -> AgentSettingsPageController) throws {
        guard controllers.isEmpty else { throw PetError("请先关闭当前知识页面，再恢复原阅读记录") }
        var restored: [AgentSettingsPageController] = []
        do {
            for page in value.readers { restored.append(try reader(page)) }
            identity = value.identity; makeRoot = make
            if !restored.isEmpty || value.root == "wiki" || value.wikiCatalog != nil {
                root = "wiki"
                guard let catalog = make("wiki") as? AgentRepoWikiWindow else { throw PetError("知识目录暂不能显示") }
                if let position = value.wikiCatalog { try catalog.restoreWorkspaceRecovery(position) }
                guard push(catalog) else { throw PetError("知识目录暂不能显示") }
                for controller in restored { guard push(controller) else { throw PetError("知识阅读器暂不能显示") } }
            }
            if value.library != nil || value.libraryVideo != nil || value.root == "library" {
                root = "library"
                guard let catalog = make("library") as? AgentKnowledgeLibraryWindow else { throw PetError("知识库暂不能显示") }
                if let library = value.library { try catalog.restoreWorkspaceRecovery(library) }
                guard push(catalog) else { throw PetError("知识库暂不能显示") }
                if let libraryVideo = value.libraryVideo {
                    let video = try catalog.restoreLocalVideo(libraryVideo)
                    guard push(video) else { video.endSettingsHosting(); throw PetError("知识库视频暂不能显示") }
                }
            }
            root = value.root
            displayCurrent(); recoveryChanged()
        } catch {
            restored.forEach { $0.endSettingsHosting() }; finish(); throw error
        }
    }
    func finish() {
        for entries in stacks.values { for entry in entries.reversed() { entry.controller.endSettingsHosting() } }
        stacks = [:]; identity = ""; makeRoot = nil
        for view in body.subviews where view !== empty { view.removeFromSuperview() }; updateHeader(); recoveryChanged()
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
        let checks = ["currentPageIsVisible": !isHiddenOrHasHiddenAncestor && currentController?.isPageVisible == true,
                      "currentPageUsesOwnerWindow": currentController?.pageContentView?.window === window && currentController?.presentingWindow === window,
                      "noFloatingKnowledgeWindows": controllers.allSatisfy { $0.window?.isVisible != true },
                      "allActionsInsideMainContent": !frames.isEmpty && frames.allSatisfy { $0["inside"] as? Bool == true },
                      "rootTabsShownAtCatalog": tabs.isHidden == ((stacks[root]?.count ?? 0) > 1),
                      "readableMainColumn": body.bounds.width >= 500 && body.bounds.width <= 825 && body.bounds.height >= 290]
        let focused = window?.firstResponder as? NSView
        return ["root": root, "depth": stacks[root]?.count ?? 0, "controller": currentController.map { String(describing: type(of: $0)) } ?? "", "pageTitle": title.stringValue, "visible": !isHiddenOrHasHiddenAncestor && window?.isVisible == true, "focusInPage": currentController?.pageContentView.map { focused?.isDescendant(of: $0) == true } ?? false, "size": [bounds.width, bounds.height], "bodySize": [body.bounds.width, body.bounds.height], "backVisible": !back.isHidden, "controls": frames, "checks": checks]
    }
}
