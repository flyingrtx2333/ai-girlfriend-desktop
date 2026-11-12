import AppKit

@MainActor final class AgentPluginReviewPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private struct Item { let title: String, detail: String }
    private let types = NSSegmentedControl(), list = NSTableView(), preview = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(), cancel = NSButton(title: "取消", target: nil, action: nil)
    private var sections: [[Item]] = [], working = false, finished = false
    var onApply: (() throws -> AgentPluginInstallation)? { didSet { apply.isEnabled = onApply != nil && !working && !finished } }
    var onApplied: ((AgentPluginInstallation) -> Void)?
    private var items: [Item] { sections[max(0, types.selectedSegment)] }

    init(package: AgentPluginPackage, installed: AgentPluginInstallation?, oldFiles: [String: Data], restoring: Bool, activating: Bool, workspace: String?) {
        let action = activating ? "启用" : installed == nil ? "安装" : restoring ? "恢复" : "更新"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = action + "插件"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        func body(_ data: Data?) -> String {
            guard let data else { return "此版本不含该文件。" }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return "二进制文件 · \(data.count) 字节" }
            return text
        }
        var components = package.receipt.components.map { component in
            Item(title: (component.kind == .skill ? "Skill · " : "命令 · ") + component.name, detail: component.path + "\n\n" + body(package.files[component.path]))
        }
        components += package.mcpServers.map { Item(title: "MCP · " + $0.key, detail: $0.destination + ($0.fields.isEmpty ? "" : "\n\n" + $0.fields.joined(separator: "\n"))) }
        components += package.agents.map { Item(title: "Agent · " + $0.key, detail: $0.summary + "\n\n" + $0.profile.instructions) }
        for config in package.hooks { for hook in config.preview { components.append(Item(title: "Hook · " + hook.name, detail: hook.event.rawValue + "\n\n" + hook.display)) } }
        components += package.rules.map { Item(title: "规则 · " + $0.key, detail: $0.trigger.title + ($0.patterns.isEmpty ? "" : " · " + $0.patterns.joined(separator: ", ")) + "\n\n" + $0.body) }
        let paths = Set(oldFiles.keys).union(package.files.keys).sorted().filter { oldFiles[$0] != package.files[$0] }
        let changes = paths.map { path in
            let change = oldFiles[path] == nil ? "新增" : package.files[path] == nil ? "移除" : "变更"
            return Item(title: change + " · " + path, detail: path + "\n\n当前版本\n" + body(oldFiles[path]) + "\n\n候选版本\n" + body(package.files[path]))
        }
        sections = [components, changes]
        types.segmentCount = 2; types.trackingMode = .selectOne
        types.setLabel("组件（\(components.count)）", forSegment: 0); types.setLabel("文件变更（\(changes.count)）", forSegment: 1)
        types.selectedSegment = installed != nil && !activating ? 1 : 0; types.target = self; types.action = #selector(changeType)
        types.setAccessibilityLabel("插件审阅内容")
        let heading = NSTextField(wrappingLabelWithString: action + "「" + package.metadata.title + "」"); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let version = installed.map { ($0.metadata.version.isEmpty ? "未标版本" : $0.metadata.version) + (activating ? "" : " → " + (package.metadata.version.isEmpty ? "未标版本" : package.metadata.version)) } ?? package.metadata.version
        let metadata = NSTextField(labelWithString: [workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户", version, package.metadata.author, package.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
        metadata.font = .systemFont(ofSize: 12); metadata.textColor = AgentWorkbenchTheme.secondaryText; metadata.lineBreakMode = .byTruncatingMiddle; metadata.toolTip = metadata.stringValue; metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let consequence = NSTextField(wrappingLabelWithString: "完成后停用；旧版本、任务记录和本机配置保留，组件需重新选择及配置。")
        consequence.font = .systemFont(ofSize: 12); consequence.textColor = AgentWorkbenchTheme.secondaryText; consequence.isHidden = installed == nil || activating
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("review"))); list.headerView = nil; list.rowHeight = 36; list.dataSource = self; list.delegate = self; list.setAccessibilityLabel("插件审阅列表")
        let index = NSScrollView(); index.documentView = list; index.hasVerticalScroller = true
        preview.isRichText = false; preview.isEditable = false; preview.isSelectable = true; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.layoutManager?.allowsNonContiguousLayout = true
        preview.setAccessibilityLabel("插件审阅详情")
        let detail = NSScrollView(); detail.documentView = preview; detail.hasVerticalScroller = true
        let split = NSStackView(views: [index, detail]); split.spacing = 12; split.alignment = .top; split.distribution = .fill
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed; status.isHidden = true
        apply.title = activating ? "审阅并启用" : installed == nil ? "安装" : action + "并停用"; apply.target = self; apply.action = #selector(applyReview); apply.isEnabled = false
        cancel.target = self; cancel.action = #selector(cancelReview)
        let footer = NSStackView(views: [NSView(), cancel, apply]); footer.spacing = 10
        let layout = NSStackView(views: [heading, metadata, consequence, types, split, status, footer]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10; layout.distribution = .fill
        let root = AgentThemeView(); window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in [heading, metadata, consequence, types, split, status, footer] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            index.widthAnchor.constraint(equalToConstant: 180), index.heightAnchor.constraint(equalTo: split.heightAnchor), detail.heightAnchor.constraint(equalTo: split.heightAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        changeType()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(list) }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }; let label = NSTextField(labelWithString: items[row].title)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = items[row].title; return label
    }
    @objc private func changeType() {
        list.reloadData()
        if items.isEmpty { list.deselectAll(nil); preview.string = "暂无内容" }
        else { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); showSelection() }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    private func showSelection() {
        guard items.indices.contains(list.selectedRow) else { return }; preview.string = items[list.selectedRow].detail; preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    @objc private func applyReview() {
        guard !working, !finished, let onApply else { return }
        working = true; apply.isEnabled = false; cancel.isEnabled = false
        do { let item = try onApply(); finished = true; working = false; close(); onApplied?(item) }
        catch { status.stringValue = error.localizedDescription; status.isHidden = false; working = false; apply.isEnabled = true; cancel.isEnabled = true }
    }
    @objc private func cancelReview() { guard !working else { return }; close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
}
