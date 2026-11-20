import AppKit

@MainActor final class AgentPluginMarketPage: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    private let plugins: AgentPlugins, workspace: String?
    private let address = AgentDialogTextField(), search = NSSearchField(), categories = NSPopUpButton(), saved = NSPopUpButton()
    private let table = AgentSettingsCatalogTable(), status = AgentSettingsStatusField("插件市场状态")
    private let refresh = AgentDialogButton(title: "加载目录", target: nil, action: nil)
    private let remove = AgentDialogButton(title: "移除目录", target: nil, action: nil)
    private let review = AgentDialogButton(title: "审阅插件", target: nil, action: nil)
    private let savedRow = NSStackView()
    private var catalogs = AgentPluginMarket.Catalogs(), entries: [AgentPluginMarket.Entry] = [], installations: [AgentPluginInstallation] = []
    private var directory: AgentPluginMarket.Directory? { catalogs.selected }
    private var job: Task<Void, Never>?
    var onReview: ((AgentPluginPackage, AgentPluginInstallation?) -> Void)?

    init(plugins: AgentPlugins, workspace: String?) {
        self.plugins = plugins; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "插件市场"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        address.placeholderString = "HTTPS 目录或 Git 仓库地址"; address.setAccessibilityLabel("插件市场目录地址")
        address.target = self; address.action = #selector(loadDirectory)
        AgentSettingsStyle.field(address); address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(loadDirectory); AgentDialogStyle.action(refresh)
        let source = NSStackView(views: [address, refresh]); source.spacing = 8
        source.heightAnchor.constraint(equalToConstant: 28).isActive = true
        saved.setAccessibilityLabel("已保存的插件目录")
        saved.target = self; saved.action = #selector(changeDirectory)
        saved.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saved.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remove.target = self; remove.action = #selector(removeDirectory); AgentDialogStyle.action(remove)
        savedRow.spacing = 8; savedRow.addArrangedSubview(saved); savedRow.addArrangedSubview(remove)
        savedRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let sources = NSStackView(views: [savedRow, source]); sources.orientation = .vertical; sources.alignment = .leading; sources.spacing = 6
        savedRow.widthAnchor.constraint(equalTo: sources.widthAnchor).isActive = true
        source.widthAnchor.constraint(equalTo: sources.widthAnchor).isActive = true
        search.placeholderString = "搜索插件"; search.setAccessibilityLabel("搜索市场插件"); search.delegate = self
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        categories.setAccessibilityLabel("市场插件分类"); categories.target = self; categories.action = #selector(filterEntries)
        let filters = NSStackView(views: [search, categories]); filters.spacing = 8
        review.target = self; review.action = #selector(prepareSelection); AgentSettingsStyle.primaryAction(review)
        table.addTableColumn(NSTableColumn(identifier: .init("market-plugin"))); table.headerView = nil
        table.setAccessibilityLabel("插件市场列表"); table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(prepareSelection); table.onOpen = { [weak self] in self?.prepareSelection() }
        let catalog = AgentSettingsCatalog.content(table: table, toolbar: filters, status: status, actions: [review], symbol: "puzzlepiece.extension")
        let root = AgentThemeView(), sourceHost = NSView(), content = NSStackView(views: [sourceHost, catalog])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        sourceHost.addSubview(sources); sources.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sources.leadingAnchor.constraint(equalTo: sourceHost.leadingAnchor, constant: 16), sources.trailingAnchor.constraint(equalTo: sourceHost.trailingAnchor, constant: -16),
            sources.topAnchor.constraint(equalTo: sourceHost.topAnchor), sources.bottomAnchor.constraint(equalTo: sourceHost.bottomAnchor),
            catalog.widthAnchor.constraint(equalTo: content.widthAnchor), sourceHost.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.contentView = root
        do { display(try plugins.market.cachedCatalogs()) }
        catch { display(.init()); status.showSaveFailure(error) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var usesInternalScrolling: Bool { true }
    override var minimumSettingsContentHeight: CGFloat { 230 }

    override func settingsDidAppear() {
        super.settingsDidAppear()
        reloadInstalled()
        presentingWindow?.makeFirstResponder(directory == nil ? address : table)
    }
    override func settingsWillLeave() { job?.cancel() }
    func windowWillClose(_ notification: Notification) { job?.cancel() }

    private func display(_ updated: AgentPluginMarket.Catalogs) {
        if updated.selection != catalogs.selection {
            search.stringValue = ""
            if categories.numberOfItems > 0 { categories.selectItem(at: 0) }
            entries = []
        }
        catalogs = updated
        saved.removeAllItems()
        for directory in catalogs.directories {
            let host = directory.address.host ?? ""
            let title = directory.publisher + " · " + directory.name + " · " + host
            let address = directory.address.absoluteString
            saved.addItem(withTitle: saved.itemTitles.contains(title) ? title + " · " + address : title)
            saved.lastItem?.toolTip = address
        }
        if let position = catalogs.directories.firstIndex(where: { $0.address == catalogs.selection }) {
            saved.selectItem(at: position)
        }
        savedRow.isHidden = catalogs.directories.isEmpty
        address.stringValue = directory?.address.absoluteString ?? ""
        refreshDirectoryView()
    }

    @objc private func changeDirectory() {
        let offset = saved.indexOfSelectedItem
        guard catalogs.directories.indices.contains(offset) else { return }
        do {
            let index = try plugins.market.select(catalogs.directories[offset].address)
            status.stringValue = ""
            display(index)
        } catch {
            display(catalogs)
            showFailure(error)
        }
    }

    @objc private func removeDirectory() {
        guard let directory, let host = presentingWindow else { return }
        let alert = AgentConfirmation()
        alert.messageText = "移除「\(directory.publisher)」目录？"
        alert.informativeText = "可用原地址重新添加。已安装的插件可在插件列表管理。"
        alert.addButton(withTitle: "移除目录").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginModal(in: host) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let index = try plugins.market.remove(directory.address)
                status.stringValue = ""
                display(index)
            } catch { showFailure(error) }
        }
    }

    private func refreshDirectoryView() {
        let scope = workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户"
        detailHeading = .init(title: "插件市场", scope: [scope, directory?.publisher ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                              location: directory?.address.host)
        let previous = categories.titleOfSelectedItem
        categories.removeAllItems(); categories.addItem(withTitle: "全部分类")
        let all = Set((directory?.entries ?? []).map(\.category).filter { !$0.isEmpty && $0 != "全部分类" })
        categories.addItems(withTitles: all.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        if let previous, categories.itemTitles.contains(previous) { categories.selectItem(withTitle: previous) }
        reloadInstalled()
    }

    private func reloadInstalled() {
        do { installations = try plugins.catalog(workspace: workspace, onlyScope: true) }
        catch { status.showSaveFailure(error) }
        filterEntries()
    }

    private var selected: AgentPluginMarket.Entry? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    private func installed(_ entry: AgentPluginMarket.Entry) -> AgentPluginInstallation? {
        guard let directory else { return nil }
        return installations.first { $0.receipt.marketOrigin?.matches(directory, entry: entry.name) == true }
    }
    private func samePackage(_ entry: AgentPluginMarket.Entry, as item: AgentPluginInstallation?) -> Bool {
        guard let item else { return false }
        return entry.source?.matches(item.receipt) == true
    }

    @objc private func filterEntries() {
        let previous = selected?.name
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = categories.indexOfSelectedItem > 0 ? categories.titleOfSelectedItem : nil
        entries = (directory?.entries ?? []).filter { entry in
            (category == nil || entry.category == category) && (query.isEmpty || entry.searchable.localizedCaseInsensitiveContains(query))
        }
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: entries.firstIndex { $0.name == previous } ?? 0), byExtendingSelection: false) }
        AgentSettingsStyle.listState(table, text: directory == nil ? "输入目录地址开始浏览" : query.isEmpty && category == nil ? "目录暂无插件" : "未找到匹配插件")
        updateControls()
    }
    func controlTextDidChange(_ notification: Notification) { filterEntries() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 78 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row], current = installed(entry)
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let state = entry.unavailable ?? current.map { samePackage(entry, as: $0) ? "已安装" : "当前 \($0.metadata.version.isEmpty ? "未标版本" : $0.metadata.version)" } ?? ""
        let details = [entry.author, entry.category, entry.version, state, entry.source?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let subtitle = NSTextField(labelWithString: details), note = NSTextField(labelWithString: entry.description)
        for field in [title, subtitle, note] { field.lineBreakMode = .byTruncatingTail; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for field in [subtitle, note] { field.font = .systemFont(ofSize: 11); field.textColor = AgentWorkbenchTheme.secondaryText; field.isHidden = field.stringValue.isEmpty }
        note.toolTip = entry.description
        let stack = NSStackView(views: [title, subtitle, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        let cell = NSTableCellView(); cell.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        cell.setAccessibilityLabel([entry.title, details, entry.description].filter { !$0.isEmpty }.joined(separator: "，"))
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    private func updateControls() {
        let ready = job == nil
        address.isEnabled = ready; refresh.isEnabled = ready; search.isEnabled = ready && directory != nil
        saved.isEnabled = ready && catalogs.directories.count > 1; remove.isEnabled = ready && directory != nil
        categories.isEnabled = ready && categories.numberOfItems > 1; table.isEnabled = ready
        let item = selected, current = item.flatMap(installed)
        review.title = current == nil ? "审阅安装" : "审阅更新"
        review.isEnabled = ready && item?.source != nil && item?.unavailable == nil && !(item.map { samePackage($0, as: current) } ?? false)
    }

    @objc private func loadDirectory() {
        guard job == nil else { return }
        let text = address.stringValue
        status.stringValue = "正在加载目录…"
        job = Task { [weak self] in
            guard let self else { return }; defer { job = nil; updateControls() }
            do {
                let loaded = try await plugins.market.refresh(text); try Task.checkCancellation()
                status.stringValue = ""
                display(loaded)
            } catch { if !Task.isCancelled { showFailure(error) } }
        }
        updateControls()
    }

    @objc private func prepareSelection() {
        guard review.isEnabled, let selected, let directory, job == nil else { return }
        status.stringValue = "正在下载并检查插件包…"
        job = Task { [weak self] in
            guard let self else { return }; defer { job = nil; updateControls() }
            do {
                let (package, old) = try await plugins.market.prepare(selected, in: directory, scope: workspace, plugins: plugins)
                try Task.checkCancellation(); status.stringValue = ""; onReview?(package, old)
            } catch { if !Task.isCancelled { showFailure(error) } }
        }
        updateControls()
    }

    func didApply(_ installed: AgentPluginInstallation, updating: Bool) {
        reloadInstalled()
        status.stringValue = "已" + (updating ? "更新" : "安装") + "「" + installed.metadata.title + "」 · 已停用"
    }
    func showFailure(_ error: Error) { status.showSaveFailure(error) }
}
