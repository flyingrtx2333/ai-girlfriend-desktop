import AppKit

@MainActor final class AgentPluginReviewPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct HistoryTarget: Codable, Equatable {
        let receiptHash: String, revision: String
    }
    private struct HistoryRecovery: Codable {
        var version = 1
        let target: HistoryTarget, showingFiles: Bool, selectedPath: String?, selectedComponent: Int
        let query: String, fullText: Bool, tableY: Double
        let selectedVisible: Bool?
        let filterSelection: AgentTextViewport.Selection?, reading: AgentTextViewport?
    }
    private struct Item { let title: String, detail: String }
    private struct FileChange: Sendable {
        let path: String, before: Data?, after: Data?
        var title: String { (before == nil ? "新增" : after == nil ? "移除" : "变更") + " · " + path }

        func patch(protectedData: URL) async throws -> String {
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bluefatfish-plugin-review-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = try AgentFiles(workspace: directory.path)
            let left = try files.literalURL("current"), right = try files.literalURL("candidate")
            try files.writeData(before ?? Data(), to: left, permissions: 0o600)
            try files.writeData(after ?? Data(), to: right, permissions: 0o600)
            let patch = try await AgentChanges.fileDiff(left: left, right: right, directory: directory, protectedData: protectedData)
            // This reader already identifies the selected file above the patch.
            guard let hunk = patch.range(of: "\n@@ ") else { return "" }
            return String(patch[patch.index(after: hunk.lowerBound)...])
        }
    }

    private let types = NSSegmentedControl(), list = NSTableView(), search = NSSearchField()
    private let preview = NSTextView(), diff = AgentGitDiffView()
    private let full = NSScrollView(), localHeading = NSStackView(), reading = NSStackView()
    private let currentPath = NSTextField(labelWithString: "")
    private let comparison = NSSegmentedControl(labels: ["差异", "全文"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = AgentSettingsStatusField("插件审阅状态")
    private let apply = AgentDialogButton(title: "安装", target: nil, action: nil), cancel = AgentDialogButton(title: "取消", target: nil, action: nil)
    private let protectedData: URL
    private let historyTarget: HistoryTarget?
    private var pendingHistory: HistoryRecovery?
    private var components: [Item] = [], files: [FileChange] = [], visibleFiles: [FileChange] = []
    private var selectedComponent: Int = 0, selectedPath: String?
    private var selecting = false, working = false, finished = false
    private var comparisonJob: Task<Void, Never>?
    var onApply: (() throws -> AgentPluginInstallation)? { didSet { apply.isEnabled = onApply != nil && !working && !finished } }
    var onApplied: ((AgentPluginInstallation) -> Void)?
    private var showingFiles: Bool { types.selectedSegment == 1 }

    init(package: AgentPluginPackage, installed: AgentPluginInstallation?, oldFiles: [String: Data], restoring: Bool, activating: Bool,
         workspace: String?, protectedData: URL, historyTarget: HistoryTarget? = nil) {
        self.protectedData = protectedData; self.historyTarget = historyTarget
        let action = activating ? "启用" : installed == nil ? "安装" : restoring ? "恢复" : "更新"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = action + "插件"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        components = package.receipt.components.map { component in
            Item(title: (component.kind == .skill ? "Skill · " : "命令 · ") + component.name, detail: component.path + "\n\n" + Self.body(package.files[component.path]))
        }
        components += package.mcpServers.map { Item(title: "MCP · " + $0.key, detail: $0.destination + ($0.fields.isEmpty ? "" : "\n\n" + $0.fields.joined(separator: "\n"))) }
        components += package.agents.map { Item(title: "Agent · " + $0.key, detail: $0.summary + "\n\n" + $0.profile.instructions) }
        for config in package.hooks { for hook in config.preview { components.append(Item(title: "Hook · " + hook.name, detail: hook.event.rawValue + "\n\n" + hook.display)) } }
        components += package.rules.map { Item(title: "规则 · " + $0.key, detail: $0.trigger.title + ($0.patterns.isEmpty ? "" : " · " + $0.patterns.joined(separator: ", ")) + "\n\n" + $0.body) }
        let paths = Set(oldFiles.keys).union(package.files.keys).sorted().filter { oldFiles[$0] != package.files[$0] }
        files = paths.map { FileChange(path: $0, before: oldFiles[$0], after: package.files[$0]) }
        types.segmentCount = 2; types.trackingMode = .selectOne
        types.setLabel("组件（\(components.count)）", forSegment: 0); types.setLabel("文件变更（\(files.count)）", forSegment: 1)
        types.selectedSegment = installed != nil && !activating ? 1 : 0; types.target = self; types.action = #selector(changeType)
        types.setAccessibilityLabel("插件审阅内容")
        let title = action + "「" + package.metadata.title + "」"
        let candidate = package.metadata.version.isEmpty ? "未标版本" : package.metadata.version
        let version = installed.map { ($0.metadata.version.isEmpty ? "未标版本" : $0.metadata.version) + (activating ? "" : " → " + candidate) } ?? candidate
        let scope = [workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户", version].joined(separator: " · ")
        detailHeading = .init(title: title, scope: scope, location: package.receipt.sourceName)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold); heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); heading.toolTip = title
        localHeading.orientation = .vertical; localHeading.alignment = .leading; localHeading.spacing = 4
        localHeading.addArrangedSubview(heading); localHeading.addArrangedSubview(Self.metadataLabel(scope))
        heading.widthAnchor.constraint(equalTo: localHeading.widthAnchor).isActive = true
        let metadata = Self.metadataLabel([package.metadata.author, package.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
        let consequence = NSTextField(wrappingLabelWithString: "完成后停用并保留旧版本。重新启用时需核对组件配置。")
        consequence.font = .systemFont(ofSize: 12); consequence.textColor = AgentWorkbenchTheme.secondaryText; consequence.isHidden = installed == nil || activating
        search.placeholderString = "筛选文件"; search.setAccessibilityLabel("筛选插件变更文件"); search.delegate = self
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(lessThanOrEqualToConstant: 176).isActive = true
        let controls = NSStackView(views: [types, NSView(), search]); controls.alignment = .centerY; controls.spacing = 8
        controls.heightAnchor.constraint(equalToConstant: 28).isActive = true
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("review"))); list.headerView = nil; list.rowHeight = 36; list.dataSource = self; list.delegate = self; list.setAccessibilityLabel("插件审阅列表")
        let index = NSScrollView(); index.documentView = list; index.hasVerticalScroller = true
        preview.isRichText = false; preview.isEditable = false; preview.isSelectable = true; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.layoutManager?.allowsNonContiguousLayout = true
        preview.setAccessibilityLabel("插件审阅详情")
        full.documentView = preview; full.hasVerticalScroller = true
        comparison.target = self; comparison.action = #selector(changeComparison); comparison.selectedSegment = 0
        comparison.setAccessibilityLabel("插件文件读取方式")
        currentPath.font = .monospacedSystemFont(ofSize: 11, weight: .medium); currentPath.lineBreakMode = .byTruncatingMiddle
        currentPath.setAccessibilityLabel("当前插件文件"); currentPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSView()
        for reader in [full, diff] {
            detail.addSubview(reader); reader.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([reader.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
                reader.trailingAnchor.constraint(equalTo: detail.trailingAnchor), reader.topAnchor.constraint(equalTo: detail.topAnchor),
                reader.bottomAnchor.constraint(equalTo: detail.bottomAnchor)])
        }
        reading.addArrangedSubview(currentPath); reading.addArrangedSubview(NSView()); reading.addArrangedSubview(comparison)
        reading.alignment = .centerY; reading.spacing = 10
        reading.heightAnchor.constraint(equalToConstant: 24).isActive = true
        comparison.setContentHuggingPriority(.required, for: .horizontal)
        let reader = NSStackView(views: [reading, detail])
        reader.orientation = .vertical; reader.alignment = .leading; reader.spacing = 8
        let split = NSStackView(views: [index, reader]); split.spacing = 12; split.alignment = .top
        apply.title = activating ? "审阅并启用" : installed == nil ? "安装" : action + "并停用"; apply.target = self; apply.action = #selector(applyReview); apply.isEnabled = false
        cancel.target = self; cancel.action = #selector(cancelReview)
        AgentSettingsStyle.primaryAction(apply); AgentDialogStyle.action(cancel)
        let actions = AgentSettingsDetailActions([cancel, apply]); detailActionRow = actions
        let layout = NSStackView(views: [localHeading, metadata, consequence, status, controls, split, actions])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 8
        let root = AgentThemeView(); window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in layout.arrangedSubviews { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            index.widthAnchor.constraint(equalToConstant: 176), index.heightAnchor.constraint(equalTo: split.heightAnchor),
            reader.heightAnchor.constraint(equalTo: split.heightAnchor), reading.widthAnchor.constraint(equalTo: reader.widthAnchor),
            detail.widthAnchor.constraint(equalTo: reader.widthAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        if historyTarget != nil {
            for scroll in [index, full] + [diff.text.enclosingScrollView].compactMap({ $0 }) {
                let clip = scroll.contentView; clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(readingChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(readingChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        }
        updateList()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var usesInternalScrolling: Bool { true }
    override var minimumSettingsContentHeight: CGFloat { 240 }
    override func setSettingsActionsHost(_ host: NSStackView?) {
        super.setSettingsActionsHost(host)
        localHeading.isHidden = host != nil
    }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(list); scheduleHistoryPosition() }
    override func settingsWillLeave() { comparisonJob?.cancel() }
    func windowWillClose(_ notification: Notification) { comparisonJob?.cancel() }
    func numberOfRows(in tableView: NSTableView) -> Int { showingFiles ? visibleFiles.count : components.count }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
        let label = NSTextField(labelWithString: showingFiles ? visibleFiles[row].title : components[row].title)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = label.stringValue
        return label
    }
    @objc private func changeType() {
        pendingHistory = nil; updateList(); historyChanged()
    }
    @objc private func changeComparison() {
        pendingHistory = nil; showSelection(); historyChanged()
    }
    private func updateList() {
        search.isHidden = !showingFiles
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleFiles = query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
        let row = showingFiles ? visibleFiles.firstIndex { $0.path == selectedPath } ?? 0 : selectedComponent
        selecting = true
        list.reloadData()
        if row < list.numberOfRows {
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
        } else { list.deselectAll(nil) }
        selecting = false
        showSelection()
    }
    func controlTextDidChange(_ notification: Notification) { changeType() }
    func controlTextDidBeginEditing(_ notification: Notification) { historyChanged() }
    func controlTextDidEndEditing(_ notification: Notification) { historyChanged() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, list.selectedRow >= 0, list.selectedRow < list.numberOfRows else { return }
        pendingHistory = nil
        if showingFiles { selectedPath = visibleFiles[list.selectedRow].path }
        else { selectedComponent = list.selectedRow }
        showSelection(); historyChanged()
    }
    private func showSelection() {
        comparisonJob?.cancel(); comparisonJob = nil
        let row = list.selectedRow
        let file = showingFiles && visibleFiles.indices.contains(row) ? visibleFiles[row] : nil
        reading.isHidden = file == nil
        currentPath.stringValue = file?.path ?? ""; currentPath.toolTip = file?.path
        guard let file else {
            if !showingFiles, components.indices.contains(row) { showFull(components[row].detail) }
            else { showFull(showingFiles && !files.isEmpty ? "未找到匹配文件" : "暂无内容") }
            return
        }
        if comparison.selectedSegment == 1 || Self.text(file.before) == nil || Self.text(file.after) == nil {
            showFull(Self.fullText(file))
            return
        }
        showFull("正在比较…")
        comparisonJob = Task { [weak self, protectedData] in
            do {
                let patch = try await file.patch(protectedData: protectedData)
                try Task.checkCancellation()
                guard let self else { return }
                comparisonJob = nil
                if patch.isEmpty { showFull(Self.fullText(file)); return }
                full.isHidden = true; diff.isHidden = false
                diff.show(patch, oldTitle: "当前版本", newTitle: "候选版本", accessibilityContext: "插件")
                diff.layoutSubtreeIfNeeded()
                Self.rewind(diff.text)
                scheduleHistoryPosition(); historyChanged()
            } catch {
                guard !Task.isCancelled, let self else { return }
                comparisonJob = nil
                showFull("无法生成差异。以下为完整内容。\n\n" + Self.fullText(file)); historyChanged()
            }
        }
    }
    private func showFull(_ value: String) {
        diff.isHidden = true; full.isHidden = false
        preview.string = value; Self.rewind(preview)
        scheduleHistoryPosition()
    }
    @objc private func readingChanged(_ notification: Notification) {
        guard isPageVisible else { return }
        if let text = notification.object as? NSTextView, text !== preview, text !== diff.text, text !== search.currentEditor() { return }
        historyChanged()
    }
    private func historyChanged() {
        if historyTarget != nil, pendingHistory == nil { onSettingsRecoveryChange?() }
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard let historyTarget else { return nil }
        if let pendingHistory { return try AgentSettingsRecovery.page("plugin-history-review", pendingHistory) }
        let query = search.stringValue, filterSelection: AgentTextViewport.Selection?
        if let editor = search.currentEditor() as? NSTextView, editor === presentingWindow?.firstResponder {
            let range = editor.selectedRange(), selection = AgentTextViewport.Selection(location: range.location, length: range.length)
            filterSelection = selection.valid(in: query.utf16.count) ? selection : nil
        } else { filterSelection = nil }
        let reader = diff.isHidden ? preview : diff.text
        let reading = comparisonJob == nil ? try AgentTextViewport(reader) : nil
        return try AgentSettingsRecovery.page("plugin-history-review", HistoryRecovery(target: historyTarget, showingFiles: showingFiles,
            selectedPath: selectedPath, selectedComponent: selectedComponent, query: query, fullText: comparison.selectedSegment == 1,
            tableY: max(0, list.enclosingScrollView?.contentView.bounds.minY ?? 0), selectedVisible: AgentSettingsRecovery.selectionIsVisible(in: list),
            filterSelection: filterSelection, reading: reading))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugin-history-review", let historyTarget else { throw PetError("设置记录不属于插件历史审阅") }
        let object = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "target", "showingFiles", "selectedPath",
            "selectedComponent", "query", "fullText", "tableY", "selectedVisible", "filterSelection", "reading"])
        if let target = object["target"] { _ = try AgentSettingsRecovery.object(target, keys: ["receiptHash", "revision"]) }
        if let selection = object["filterSelection"] { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        if let text = object["reading"] { try AgentTextViewport.validateObject(text) }
        let value = try JSONDecoder().decode(HistoryRecovery.self, from: page.state)
        guard value.version == 1, value.target == historyTarget, AgentSettingsRecovery.validScroll(value.tableY),
              value.selectedPath.map({ path in files.contains { $0.path == path } }) != false,
              value.selectedComponent == 0 || components.indices.contains(value.selectedComponent),
              value.filterSelection?.valid(in: value.query.utf16.count) != false, value.reading?.valid != false else {
            throw PetError("插件历史审阅与原记录不一致，请重新打开历史版本")
        }
        pendingHistory = value; selectedPath = value.selectedPath; selectedComponent = value.selectedComponent
        types.selectedSegment = value.showingFiles ? 1 : 0; comparison.selectedSegment = value.fullText ? 1 : 0
        search.stringValue = value.query; updateList()
    }
    private func scheduleHistoryPosition() {
        guard pendingHistory != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, isPageVisible, comparisonJob == nil, let value = pendingHistory else { return }
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if let scroll = list.enclosingScrollView { AgentSettingsRecovery.restoreScroll(value.tableY, to: scroll) }
            if value.selectedVisible == true, list.selectedRow >= 0 { list.scrollRowToVisible(list.selectedRow) }
            value.reading?.apply(to: diff.isHidden ? preview : diff.text, focus: value.filterSelection == nil)
            if let selection = value.filterSelection, !search.isHidden, presentingWindow?.makeFirstResponder(search) == true {
                (search.currentEditor() as? NSTextView)?.setSelectedRange(selection.range)
            }
            pendingHistory = nil; historyChanged()
        }
    }
    private static func rewind(_ text: NSTextView) {
        guard let viewport = text.enclosingScrollView else { return }
        viewport.contentView.scroll(to: .zero)
        viewport.reflectScrolledClipView(viewport.contentView)
    }
    private static func metadataLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12); label.textColor = AgentWorkbenchTheme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = text; label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private static func text(_ data: Data?) -> String? {
        guard let data else { return "" }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func body(_ data: Data?) -> String {
        guard let data else { return "此版本不含该文件。" }
        return text(data) ?? "二进制文件 · \(data.count) 字节"
    }
    private static func fullText(_ file: FileChange) -> String {
        file.path + "\n\n当前版本\n" + body(file.before) + "\n\n候选版本\n" + body(file.after)
    }
    @objc private func applyReview() {
        guard !working, !finished, let onApply else { return }
        working = true; apply.isEnabled = false; cancel.isEnabled = false
        do { let item = try onApply(); finished = true; working = false; close(); onApplied?(item) }
        catch { status.showSaveFailure(error); working = false; apply.isEnabled = true; cancel.isEnabled = true }
    }
    @objc private func cancelReview() { guard !working else { return }; close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
}
