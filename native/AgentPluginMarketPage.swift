import AppKit

@MainActor final class AgentPluginMarketPage: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    private struct Recovery: Codable {
        var version = 1
        let workspace: String?, catalogHash: String?, entry: String?, category: String?
        let query: String, y: Double, selectedVisible: Bool
        let querySelection: AgentTextViewport.Selection?
    }
    private let plugins: AgentPlugins, workspace: String?
    private let address = AgentDialogTextField(), search = AgentSettingsSidebarSearchField()
    private let categories = NSPopUpButton(), saved = NSPopUpButton(), directoryActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let table = AgentSettingsCatalogTable(), status = AgentSettingsStatusField("插件市场状态"), sourceStatus = AgentSettingsStatusField("市场目录状态")
    private let refresh = AgentDialogButton(title: "加载目录", target: nil, action: nil)
    private let credentials = AgentDialogButton(title: "访问凭据", target: nil, action: nil)
    private let remove = NSMenuItem(title: "移除目录", action: nil, keyEquivalent: "")
    private let review = AgentDialogButton(title: "审阅插件", target: nil, action: nil)
    private let savedRow = NSStackView(), filters = NSStackView(), emptySpace = NSView()
    private lazy var categoryFrame = AgentSettingsPopupFrame(categories)
    private lazy var savedFrame = AgentSettingsPopupFrame(saved, outlined: true, maximumWidth: nil)
    private lazy var directoryActionsFrame = AgentSettingsPopupFrame(directoryActions)
    private lazy var catalog = AgentSettingsCatalogPage(table: table, toolbar: filters, status: status, actions: [review], symbol: "puzzlepiece.extension")
    private var catalogs = AgentPluginMarket.Catalogs(), entries: [AgentPluginMarket.Entry] = [], installations: [AgentPluginInstallation] = []
    private var directory: AgentPluginMarket.Directory? { catalogs.selected }
    private var job: Task<Void, Never>?
    private var pendingRecovery: Recovery?
    private var positionScheduled = false
    var onReview: ((AgentPluginPackage, AgentPluginInstallation?) throws -> Void)?
    var restoreReview: ((AgentPluginReviewPage.DraftTarget) throws -> AgentPluginReviewPage)?

    init(plugins: AgentPlugins, workspace: String?) {
        self.plugins = plugins; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "插件市场"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        address.placeholderString = "HTTPS 目录或 Git 仓库地址"; address.setAccessibilityLabel("插件市场目录地址")
        address.target = self; address.action = #selector(loadDirectory)
        AgentSettingsStyle.field(address); address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(loadDirectory); AgentDialogStyle.action(refresh)
        credentials.target = self; credentials.action = #selector(editCredentials); AgentDialogStyle.action(credentials)
        let source = NSStackView(views: [address, credentials, refresh]); source.alignment = .centerY; source.spacing = 8
        address.heightAnchor.constraint(equalToConstant: 28).isActive = true
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true
        saved.setAccessibilityLabel("已保存的插件目录")
        saved.target = self; saved.action = #selector(changeDirectory)
        saved.cell?.lineBreakMode = .byTruncatingMiddle
        directoryActions.addItem(withTitle: "更多")
        directoryActions.setAccessibilityLabel("市场目录操作")
        directoryActions.menu?.autoenablesItems = false
        remove.target = self; remove.action = #selector(removeDirectory); directoryActions.menu?.addItem(remove)
        directoryActionsFrame.widthAnchor.constraint(equalToConstant: 76).isActive = true
        savedRow.alignment = .centerY; savedRow.spacing = 8
        savedRow.addArrangedSubview(savedFrame); savedRow.addArrangedSubview(directoryActionsFrame)
        let sources = NSStackView(views: [savedRow, source, sourceStatus]); sources.orientation = .vertical; sources.alignment = .leading; sources.spacing = 8
        for row in sources.arrangedSubviews { row.widthAnchor.constraint(equalTo: sources.widthAnchor).isActive = true }
        search.placeholderString = "搜索插件"; search.setAccessibilityLabel("搜索市场插件"); search.delegate = self
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        categories.setAccessibilityLabel("市场插件分类"); categories.target = self; categories.action = #selector(filterEntries)
        categories.cell?.lineBreakMode = .byTruncatingTail
        categoryFrame.widthAnchor.constraint(equalToConstant: 128).isActive = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        filters.alignment = .centerY; filters.spacing = 8
        filters.addArrangedSubview(search); filters.addArrangedSubview(categoryFrame)
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true
        review.target = self; review.action = #selector(prepareSelection); AgentSettingsStyle.primaryAction(review)
        table.addTableColumn(NSTableColumn(identifier: .init("market-plugin"))); table.headerView = nil
        table.setAccessibilityLabel("插件市场列表"); table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(prepareSelection); table.onOpen = { [weak self] in self?.prepareSelection() }
        AgentSettingsStyle.prepare(catalog)
        let root = AgentThemeView(), sourceHost = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        sourceHost.layer?.cornerRadius = 10; sourceHost.layer?.borderWidth = 1
        let content = NSStackView(views: [sourceHost, catalog, emptySpace])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        sourceHost.addSubview(sources); sources.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sources.leadingAnchor.constraint(equalTo: sourceHost.leadingAnchor, constant: 16), sources.trailingAnchor.constraint(equalTo: sourceHost.trailingAnchor, constant: -16),
            sources.topAnchor.constraint(equalTo: sourceHost.topAnchor, constant: 12), sources.bottomAnchor.constraint(equalTo: sourceHost.bottomAnchor, constant: -12),
            catalog.widthAnchor.constraint(equalTo: content.widthAnchor), sourceHost.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.contentView = root
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(positionChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        do { display(try plugins.market.cachedCatalogs()) }
        catch { display(.init()); sourceStatus.showSaveFailure(error) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var usesInternalScrolling: Bool { true }
    override var minimumSettingsContentHeight: CGFloat { 230 }
    override func setSettingsActionsHost(_ host: NSStackView?) { catalog.setActionsHost(host) }

    override func settingsDidAppear() {
        super.settingsDidAppear()
        reloadInstalled()
        presentingWindow?.makeFirstResponder(directory == nil ? address : table)
        schedulePosition()
    }
    override func pageDidLayout() { schedulePosition() }
    override func settingsWillLeave() { job?.cancel() }
    func windowWillClose(_ notification: Notification) { job?.cancel() }

    private static func catalogHash(_ address: URL) -> String { AgentFiles.hash(Data(address.absoluteString.utf8)) }

    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        if let pendingRecovery { return try AgentSettingsRecovery.page("plugin-market", pendingRecovery) }
        let query = search.stringValue
        var selection: AgentTextViewport.Selection?
        if let editor = search.currentEditor() as? NSTextView, editor === presentingWindow?.firstResponder {
            let range = editor.selectedRange(), candidate = AgentTextViewport.Selection(location: range.location, length: range.length)
            if candidate.valid(in: query.utf16.count) { selection = candidate }
        }
        return try AgentSettingsRecovery.page("plugin-market", Recovery(workspace: workspace, catalogHash: catalogs.selection.map(Self.catalogHash),
            entry: selected?.name, category: categories.indexOfSelectedItem > 0 ? categories.titleOfSelectedItem : nil,
            query: query, y: max(0, table.enclosingScrollView?.contentView.bounds.minY ?? 0),
            selectedVisible: AgentSettingsRecovery.selectionIsVisible(in: table), querySelection: selection))
    }

    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugin-market" else { throw PetError("设置记录不属于插件市场") }
        let object = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "workspace", "catalogHash",
            "entry", "category", "query", "y", "selectedVisible", "querySelection"])
        if let selection = object["querySelection"] { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.workspace == workspace, AgentSettingsRecovery.validHash(value.catalogHash),
              value.entry.map({ !$0.isEmpty && $0.utf8.count <= 128 }) != false, AgentSettingsRecovery.validScroll(value.y),
              value.querySelection?.valid(in: value.query.utf16.count) != false else {
            throw PetError("原插件市场范围或位置无效，记录已保留")
        }
        var index = catalogs
        index.selection = index.directories.first { Self.catalogHash($0.address) == value.catalogHash }?.address
        display(index)
        if value.catalogHash != nil, index.selection == nil { sourceStatus.stringValue = "原目录暂不可用" }
        search.stringValue = value.query
        if let category = value.category, categories.itemTitles.contains(category) { categories.selectItem(withTitle: category) }
        filterEntries()
        pendingRecovery = value
    }

    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "plugin-market-review" else { return nil }
        let target = try AgentPluginReviewPage.recoveryTarget(page)
        guard let restoreReview, target.workspace == workspace else { throw PetError("原市场插件审阅范围已变化，记录已保留") }
        return try restoreReview(target)
    }

    private func schedulePosition() {
        guard pendingRecovery != nil, !positionScheduled else { return }
        positionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { positionScheduled = false }
            guard isPageVisible, let value = pendingRecovery, let scroll = table.enclosingScrollView else { return }
            if let row = entries.firstIndex(where: { $0.name == value.entry }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            AgentSettingsRecovery.restoreScroll(value.y, to: scroll)
            if value.selectedVisible, table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
            if let selection = value.querySelection, search.isEnabled, presentingWindow?.makeFirstResponder(search) == true {
                (search.currentEditor() as? NSTextView)?.setSelectedRange(selection.range)
            }
            pendingRecovery = nil; onSettingsRecoveryChange?()
        }
    }

    @objc private func positionChanged(_ notification: Notification) {
        guard pendingRecovery == nil, isPageVisible else { return }
        if let text = notification.object as? NSTextView, text !== search.currentEditor() { return }
        onSettingsRecoveryChange?()
    }

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
        } else { saved.select(nil) }
        savedRow.isHidden = catalogs.directories.isEmpty
        address.stringValue = directory?.address.absoluteString ?? ""
        refreshDirectoryView()
        onSettingsRecoveryChange?()
    }

    @objc private func changeDirectory() {
        let offset = saved.indexOfSelectedItem
        guard catalogs.directories.indices.contains(offset) else { return }
        do {
            let index = try plugins.market.select(catalogs.directories[offset].address)
            sourceStatus.stringValue = ""; status.stringValue = ""
            display(index)
        } catch {
            display(catalogs)
            sourceStatus.showSaveFailure(error)
        }
    }

    @objc private func removeDirectory() {
        guard job == nil, let directory, let host = presentingWindow else { return }
        let alert = AgentConfirmation()
        alert.messageText = "移除「\(directory.publisher)」目录？"
        alert.informativeText = "可用原地址重新添加。已安装的插件可在插件列表管理。"
        alert.addButton(withTitle: "移除目录").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginModal(in: host) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let index = try plugins.market.remove(directory.address)
                sourceStatus.stringValue = ""; status.stringValue = ""
                display(index)
            } catch { sourceStatus.showSaveFailure(error) }
        }
    }

    private func refreshDirectoryView() {
        let scope = workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户"
        detailHeading = .init(title: "插件市场", scope: scope, location: directory?.address.host)
        catalog.isHidden = directory == nil; emptySpace.isHidden = directory != nil; review.isHidden = directory == nil
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
        AgentSettingsStyle.listState(table, text: query.isEmpty && category == nil ? "目录暂无插件" : "未找到匹配插件")
        updateControls()
        if pendingRecovery == nil { onSettingsRecoveryChange?() }
    }
    func controlTextDidChange(_ notification: Notification) { filterEntries() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls(); positionChanged(notification) }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsCatalogRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row], current = installed(entry), matches = samePackage(entry, as: current)
        let unavailable = entry.unavailable ?? (entry.source == nil ? "此插件没有可用来源" : nil)
        let state = unavailable != nil ? "不可用" : current.map { _ in matches ? "已安装" : "可更新" } ?? ""
        var version = entry.version
        if let current, !matches {
            let previous = current.metadata.version.isEmpty ? "未标版本" : current.metadata.version
            version = version.isEmpty ? "当前 " + previous : previous + " → " + version
        }
        let summary = [version, entry.category, entry.description, entry.author, entry.source?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let cell = AgentSettingsCatalogCell(title: entry.title, summary: summary, symbol: "puzzlepiece.extension", status: state, group: .init(last: false))
        let detail = [summary, unavailable ?? state].filter { !$0.isEmpty }.joined(separator: "，")
        cell.toolTip = detail; cell.setAccessibilityLabel([entry.title, detail].filter { !$0.isEmpty }.joined(separator: "，"))
        return cell
    }

    private func updateControls() {
        let ready = job == nil
        address.isEnabled = ready; refresh.isEnabled = ready; search.isEnabled = ready && directory != nil
        refresh.prominent = directory == nil
        credentials.isEnabled = ready
        saved.isEnabled = ready && (catalogs.directories.count > 1 || directory == nil && !catalogs.directories.isEmpty)
        directoryActions.isEnabled = ready && directory != nil
        remove.isEnabled = ready && directory != nil
        categories.isEnabled = ready && categories.numberOfItems > 1; table.isEnabled = ready
        for frame in [savedFrame, directoryActionsFrame, categoryFrame] { frame.refreshEnabledState() }
        let item = selected, current = item.flatMap(installed)
        review.title = current == nil ? "审阅安装" : "审阅更新"
        review.isEnabled = ready && item?.source != nil && item?.unavailable == nil && !(item.map { samePackage($0, as: current) } ?? false)
    }

    @objc private func editCredentials() {
        guard job == nil else { return }
        do {
            let destination = try AgentPluginMarket.credentialDestination(address.stringValue)
            let page = AgentPluginMarketCredentialPage(market: plugins.market, destination: destination)
            page.onChange = { [weak self] saved in
                self?.sourceStatus.stringValue = saved ? "已保存访问凭据" : "已清除访问凭据"
            }
            presentSettingsChild(page)
        } catch { sourceStatus.showSaveFailure(error); presentingWindow?.makeFirstResponder(address) }
    }

    @objc private func loadDirectory() {
        guard job == nil else { return }
        let text = address.stringValue
        sourceStatus.stringValue = "正在加载目录…"; status.stringValue = ""
        job = Task { [weak self] in
            guard let self else { return }
            var focus: NSView?
            defer {
                job = nil; updateControls()
                if let focus, isPageVisible { presentingWindow?.makeFirstResponder(focus) }
            }
            do {
                let loaded = try await plugins.market.refresh(text); try Task.checkCancellation()
                sourceStatus.stringValue = ""
                display(loaded)
                focus = table
            } catch {
                if !Task.isCancelled { sourceStatus.showSaveFailure(error); focus = address }
            }
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
                try Task.checkCancellation(); status.stringValue = ""; try onReview?(package, old)
            } catch { if !Task.isCancelled { status.showSaveFailure(error) } }
        }
        updateControls()
    }

    func didApply(_ installed: AgentPluginInstallation, updating: Bool) {
        reloadInstalled()
        status.stringValue = "已" + (updating ? "更新" : "安装") + "「" + installed.metadata.title + "」 · 已停用"
    }
}
