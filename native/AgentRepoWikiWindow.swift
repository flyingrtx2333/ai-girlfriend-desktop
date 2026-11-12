import AppKit

@MainActor private final class AgentRepoWikiItem: NSCollectionViewItem {
    var onOpen: ((String) -> Void)?
    override func loadView() { view = NSView() }
    func show(_ row: AgentRepoWikiSummary, grid: Bool) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderWidth = 1
        box.borderColor = AgentWorkbenchTheme.line; box.fillColor = AgentWorkbenchTheme.surface; box.contentViewMargins = NSSize(width: 12, height: 12)
        view.addSubview(box); box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.leadingAnchor.constraint(equalTo: view.leadingAnchor), box.trailingAnchor.constraint(equalTo: view.trailingAnchor), box.topAnchor.constraint(equalTo: view.topAnchor), box.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let name = NSTextField(labelWithString: row.project.name), path = NSTextField(labelWithString: row.project.workspace)
        name.font = .systemFont(ofSize: 15, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        path.font = .systemFont(ofSize: 11); path.textColor = AgentWorkbenchTheme.secondaryText; path.lineBreakMode = .byTruncatingMiddle; path.toolTip = row.project.workspace
        let identity = NSStackView(views: [name, path]); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 5
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [name, path] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); label.widthAnchor.constraint(equalTo: identity.widthAnchor).isActive = true }
        let status = NSTextField(labelWithString: row.status + (row.branchTitle.isEmpty ? "" : " · " + row.branchTitle))
        status.font = .systemFont(ofSize: 12, weight: .medium); status.lineBreakMode = .byTruncatingMiddle
        status.textColor = row.problem != nil ? .systemRed : ["生成中", "等待确认", "待开始"].contains(row.status) ? .systemOrange : AgentWorkbenchTheme.secondaryText
        status.toolTip = row.problem ?? row.branch
        let metadata = NSTextField(labelWithString: row.pages.map { "\($0) 页" } ?? "")
        if let updated = row.updated { metadata.stringValue += " · " + DateFormatter.localizedString(from: updated, dateStyle: .short, timeStyle: .short) }
        metadata.font = .systemFont(ofSize: 11); metadata.textColor = AgentWorkbenchTheme.secondaryText; metadata.lineBreakMode = .byTruncatingTail
        let metrics = NSStackView(views: [status, metadata]); metrics.orientation = .vertical; metrics.alignment = .leading; metrics.spacing = 5
        for label in [status, metadata] { label.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true }
        let actions = NSStackView(); actions.spacing = 6
        for (title, action) in [(row.pages == 0 ? "前往生成" : "查看 Wiki", "wiki"), ("知识卡片", "cards"), ("检索", "search")] {
            let button = NSButton(title: title, target: self, action: #selector(open(_:))); button.identifier = .init(action); button.bezelStyle = .rounded; button.controlSize = .small
            button.setAccessibilityLabel(title + " · " + row.project.name); actions.addArrangedSubview(button)
        }
        let spacer = NSView(), content = NSStackView(views: [identity, metrics, spacer, actions])
        content.orientation = grid ? .vertical : .horizontal; content.alignment = grid ? .leading : .centerY; content.spacing = grid ? 12 : 18
        spacer.setContentHuggingPriority(.defaultLow, for: grid ? .vertical : .horizontal)
        if grid { for child in [identity, metrics] { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true } }
        else { metrics.widthAnchor.constraint(equalToConstant: 190).isActive = true; identity.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true }
        guard let host = box.contentView else { return }; host.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor), content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        view.setAccessibilityLabel(row.project.name + "，" + row.status + "，" + row.branchTitle); view.toolTip = row.problem
    }
    @objc private func open(_ sender: NSButton) { if let action = sender.identifier?.rawValue { onOpen?(action) } }
}

@MainActor final class AgentRepoWikiWindow: AgentSettingsPageController, NSWindowDelegate, NSCollectionViewDataSource, NSSearchFieldDelegate {
    private let store: AgentStore, collection = NSCollectionView(), flow = NSCollectionViewFlowLayout(), scroll = NSScrollView()
    private let search = NSSearchField(), status = NSPopUpButton(), language = NSPopUpButton()
    private let layout = NSSegmentedControl(labels: ["网格", "列表"], trackingMode: .selectOne, target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "暂无项目")
    private var summaries: [AgentRepoWikiSummary] = [], rows: [AgentRepoWikiSummary] = []
    private var load: Task<Void, Never>?, worker: Task<[AgentRepoWikiSummary], Error>?, loading = false, generationSignature = ""
    private var lastWidth: CGFloat = 0
    var onOpen: ((AgentRepoWikiProject, String, String) throws -> Void)?
    private var selectedLanguage: String { language.indexOfSelectedItem == 1 ? "en" : "zh" }
    init(store: AgentStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Repo Wiki"; window.minSize = NSSize(width: 780, height: 520); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        search.placeholderString = "搜索项目"; search.setAccessibilityLabel("搜索 Wiki 项目"); search.delegate = self; search.sendsSearchStringImmediately = true
        status.addItems(withTitles: ["全部状态", "已生成", "未生成"]); status.target = self; status.action = #selector(filterChanged); status.setAccessibilityLabel("Wiki 生成状态")
        language.addItems(withTitles: ["简体中文", "English"]); language.target = self; language.action = #selector(languageChanged); language.setAccessibilityLabel("项目 Wiki 语言")
        layout.selectedSegment = 0; layout.target = self; layout.action = #selector(layoutChanged); layout.setAccessibilityLabel("项目 Wiki 视图")
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!, target: self, action: #selector(reload))
        refresh.bezelStyle = .texturedRounded; refresh.setAccessibilityLabel("刷新项目 Wiki"); refresh.toolTip = "刷新"
        let add = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)!, target: self, action: #selector(addWorkspace))
        add.bezelStyle = .texturedRounded; add.setAccessibilityLabel("添加 Wiki 工作区"); add.toolTip = "添加工作区"
        let query = NSStackView(views: [search, refresh, add]), filters = NSStackView(views: [status, language, NSView(), layout])
        let toolbar = NSStackView(views: [query, filters]); toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 10
        for row in [query, filters] { row.spacing = 8; row.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        collection.collectionViewLayout = flow; collection.dataSource = self; collection.isSelectable = false; collection.backgroundColors = [.clear]; collection.setAccessibilityLabel("Wiki 项目列表")
        collection.register(AgentRepoWikiItem.self, forItemWithIdentifier: .init("repository"))
        flow.minimumInteritemSpacing = 12; flow.minimumLineSpacing = 12; flow.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        collection.frame = NSRect(x: 0, y: 0, width: 1064, height: 500); collection.autoresizingMask = [.width]
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        empty.font = .systemFont(ofSize: 15); empty.textColor = AgentWorkbenchTheme.secondaryText; empty.setAccessibilityLabel("Wiki 项目筛选状态")
        for child in [toolbar, scroll, state, empty] { content.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor), toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -12),
            state.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), state.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 100)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { load?.cancel(); worker?.cancel(); loading = false }
    func windowDidBecomeKey(_ notification: Notification) { if !loading { reload() } }
    func windowDidResize(_ notification: Notification) { window?.contentView?.layoutSubtreeIfNeeded(); updateLayout() }
    @objc func reload() {
        load?.cancel(); worker?.cancel(); loading = true; summaries = []; rows = []; collection.reloadData(); empty.isHidden = true; state.stringValue = "正在读取项目…"; state.textColor = AgentWorkbenchTheme.secondaryText
        let projects = AgentRepoWikiOverview.projects(store), storage = store.directory, selected = selectedLanguage
        generationSignature = currentGenerationSignature
        let background = Task.detached(priority: .utility) { try AgentRepoWikiOverview.read(projects, storage: storage, language: selected) }; worker = background
        load = Task { [weak self] in
            do {
                let values = try await background.value; try Task.checkCancellation()
                guard let self else { return }; self.summaries = values; self.loading = false; self.worker = nil; self.load = nil; self.applyFilter()
            } catch { guard let self, !Task.isCancelled else { return }; self.loading = false; self.worker = nil; self.load = nil; self.state.stringValue = error.localizedDescription; self.state.textColor = .systemRed }
        }
    }
    private var currentGenerationSignature: String {
        store.tasks.filter { $0.kind == "wiki" }.sorted { $0.id < $1.id }.map { "\($0.id)|\($0.status.rawValue)|\($0.archived)|\($0.wikiJob?.branch ?? "")|\($0.wikiJob?.language ?? "zh")|\(AgentWiki.isFinalizing($0.id))" }.joined(separator: "\n") + "\n\(store.organization.revision)"
    }
    func refreshLiveState() { guard presentingWindow?.isKeyWindow == true, isPageVisible, !loading, currentGenerationSignature != generationSignature else { return }; reload() }
    override func pageDidLayout() { updateLayout() }
    @objc private func filterChanged() { applyFilter() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    @objc private func languageChanged() { reload() }
    @objc private func layoutChanged() { lastWidth = 0; updateLayout(); collection.reloadData() }
    private func updateLayout() {
        let width = max(1, scroll.contentView.bounds.width); collection.frame.size.width = width
        guard width != lastWidth else { return }; lastWidth = width
        let requestedGrid = layout.selectedSegment == 0, grid = requestedGrid || width < 700, columns = requestedGrid ? max(1, Int((width + 12) / 300)) : 1
        flow.itemSize = NSSize(width: floor((width - CGFloat(columns - 1) * 12) / CGFloat(columns)), height: grid ? 184 : 94); flow.invalidateLayout()
    }
    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = AgentRepoWikiOverview.progress(summaries, store: store, language: selectedLanguage).filter { row in
            (query.isEmpty || (row.project.name + "\n" + row.project.workspace).localizedStandardContains(query)) && (status.indexOfSelectedItem == 0 || status.indexOfSelectedItem == 1 && row.published == true || status.indexOfSelectedItem == 2 && row.published == false)
        }
        collection.reloadData(); updateLayout()
        empty.isHidden = loading || !rows.isEmpty; empty.stringValue = summaries.isEmpty ? "暂无工作区" : "没有匹配的项目"
        if !loading { state.stringValue = "\(rows.count) 个项目"; state.textColor = AgentWorkbenchTheme.secondaryText }
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("repository"), for: indexPath) as! AgentRepoWikiItem, row = rows[indexPath.item]
        item.show(row, grid: layout.selectedSegment == 0 || collection.bounds.width < 700)
        item.onOpen = { [weak self] action in
            guard let self, let current = self.rows.first(where: { $0.id == row.id }) else { return }
            do { try self.onOpen?(current.project, self.selectedLanguage, action) }
            catch { self.state.stringValue = error.localizedDescription; self.state.textColor = .systemRed }
        }; return item
    }
    @objc private func addWorkspace() {
        guard let window = presentingWindow else { return }; let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "添加工作区"
        panel.beginSheetModal(for: window) { [weak self] reply in
            Task { @MainActor in
                guard let self, reply == .OK, let url = panel.url else { return }
                do { try self.store.organization.register(url.path, mode: .coding); self.reload() }
                catch { self.state.stringValue = error.localizedDescription; self.state.textColor = .systemRed }
            }
        }
    }
    var checkState: [String: Any] {
        guard CommandLine.arguments.contains("--repo-wiki-overview-check") || AgentKnowledgePageHost.readbackEnabled else { return [:] }
        return ["language": selectedLanguage, "layout": layout.selectedSegment == 0 ? "grid" : "list", "filter": status.indexOfSelectedItem, "query": search.stringValue, "loading": loading, "total": summaries.count, "message": state.stringValue,
                "rows": rows.map { row in ["workspace": row.project.workspace, "name": row.project.name, "taskID": row.project.taskID as Any? ?? NSNull(), "branch": row.branch as Any? ?? NSNull(), "status": row.status, "pages": row.pages as Any? ?? NSNull(), "published": row.published as Any? ?? NSNull(), "updated": row.updated?.timeIntervalSince1970 as Any? ?? NSNull(), "problem": row.problem as Any? ?? NSNull()] as [String: Any] },
                "itemSize": [flow.itemSize.width, flow.itemSize.height], "windowSize": [presentingWindow?.contentView?.bounds.width ?? 0, presentingWindow?.contentView?.bounds.height ?? 0]]
    }
    func checkOpen(workspace: String, action: String) throws {
        guard AgentKnowledgePageHost.readbackEnabled, let row = rows.first(where: { $0.project.workspace == workspace }) else { throw PetError("知识中心项目未载入") }
        try onOpen?(row.project, selectedLanguage, action)
    }
}
