import AppKit

@MainActor final class AgentWikiTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private final class Node: NSObject {
        let path: String, title: String, directory: Bool
        var children: [Node] = []
        weak var parent: Node?
        init(path: String, title: String, directory: Bool) { self.path = path; self.title = title; self.directory = directory; super.init() }
    }
    private let search = NSSearchField(), refresh = NSButton(), outline = NSOutlineView(), scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "暂无文档")
    private var pages: [AgentWikiPage] = [], roots: [Node] = [], nodes: [String: Node] = [:], expanded: Set<String> = []
    private var applying = false, selectedPath: String?
    private var rootPath = ".bluefatfish/wiki"
    private let language = NSPopUpButton(), plan = NSButton(title: "规划", target: nil, action: nil), more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var citationAvailable = false
    private var maintenanceAvailable = false
    var canSelect: ((String) -> Bool)?, onSelect: ((String) -> Void)?, onRefresh: (() -> Void)?
    var onLanguage: ((String) -> Bool)?, onPlan: (() -> Void)?
    var onSharing: ((String) -> Void)?
    var selectedLanguage: String { ["zh", "en", "legacy"][max(0, min(2, language.indexOfSelectedItem))] }
    var selectedDocument: String? { selectedPath }
    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "搜索 Wiki"; search.setAccessibilityLabel("搜索 Wiki 文档"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新 Wiki 目录"); refresh.bezelStyle = .texturedRounded; refresh.controlSize = .small; refresh.target = self; refresh.action = #selector(reloadCatalog); refresh.setAccessibilityLabel("刷新 Wiki 目录")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wiki")); column.width = 165; column.minWidth = 120
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil; outline.rowHeight = 28; outline.indentationPerLevel = 12; outline.delegate = self; outline.dataSource = self; outline.setAccessibilityLabel("Wiki 文档树")
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.target = self; outline.doubleAction = #selector(toggleFolder)
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        empty.textColor = AgentWorkbenchTheme.secondaryText; empty.font = .systemFont(ofSize: 12); empty.setAccessibilityLabel("Wiki 目录状态")
        let toolbar = NSStackView(views: [search, refresh]); toolbar.spacing = 4
        language.addItems(withTitles: ["简体中文", "English", "旧版"]); language.controlSize = .small; language.target = self; language.action = #selector(changeLanguage); language.setAccessibilityLabel("Wiki 语言")
        plan.controlSize = .small; plan.bezelStyle = .texturedRounded; plan.target = self; plan.action = #selector(editPlan); plan.setAccessibilityLabel("Wiki 生成规划")
        plan.title = ""; plan.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil); plan.toolTip = "规划"; plan.widthAnchor.constraint(equalToConstant: 25).isActive = true
        more.controlSize = .small; more.setAccessibilityLabel("Wiki 更多操作"); more.addItem(withTitle: ""); more.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil); more.menu?.autoenablesItems = false
        let update = NSMenuItem(title: "增量更新…", action: #selector(sharingAction(_:)), keyEquivalent: ""); update.target = self; update.representedObject = "update"; more.menu?.addItem(update)
        let regenerate = NSMenuItem(title: "重新生成 Wiki…", action: #selector(sharingAction(_:)), keyEquivalent: ""); regenerate.target = self; regenerate.representedObject = "regenerate"; more.menu?.addItem(regenerate); more.menu?.addItem(.separator())
        for (title, value) in [("导出项目知识", "knowledge-export"), ("从项目导入知识…", "knowledge-import"), ("恢复项目知识版本…", "knowledge-restore")] { let item = NSMenuItem(title: title, action: #selector(sharingAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value; more.menu?.addItem(item) }
        more.menu?.addItem(.separator())
        for (title, value) in [("导出 Wiki 到项目", "export"), ("从项目导入 Wiki…", "import"), ("恢复 Wiki 版本…", "restore"), ("打开共享目录", "open")] { let item = NSMenuItem(title: title, action: #selector(sharingAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value; more.menu?.addItem(item) }
        more.menu?.addItem(.separator())
        let citation = NSMenuItem(title: "自动引用 Wiki", action: #selector(sharingAction(_:)), keyEquivalent: ""); citation.target = self; citation.representedObject = "citation"; more.menu?.addItem(citation)
        for (title, action) in [("自动更新", "auto-update"), ("自动导出", "auto-export")] { let item = NSMenuItem(title: title, action: #selector(sharingAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = action; more.menu?.addItem(item) }
        more.widthAnchor.constraint(equalToConstant: 25).isActive = true
        let options = NSStackView(views: [language, NSView(), plan, more]); options.spacing = 4
        for child in [toolbar, options, scroll, empty] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor), refresh.widthAnchor.constraint(equalToConstant: 25), options.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4), options.leadingAnchor.constraint(equalTo: leadingAnchor), options.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setLanguage(_ value: String) { language.selectItem(at: ["zh", "en", "legacy"].firstIndex(of: value) ?? 0) }
    func setCitationState(_ enabled: Bool?, problem: String? = nil) {
        citationAvailable = enabled != nil
        let item = more.itemArray.first { $0.representedObject as? String == "citation" }
        item?.state = enabled == true ? .on : .off; item?.toolTip = problem
    }
    func setSharingState(busy: Bool, writable: Bool, canRegenerate: Bool = false) {
        language.isEnabled = !busy; more.isEnabled = !busy; plan.isEnabled = !busy
        for item in more.itemArray.dropFirst() where !item.isSeparatorItem {
            let action = item.representedObject as? String
            item.isEnabled = action == "citation" ? !busy && citationAvailable : !busy && selectedLanguage != "legacy" && (writable || action == "open") && (!["regenerate", "update"].contains(action ?? "") || canRegenerate) && (!["auto-update", "auto-export"].contains(action ?? "") || maintenanceAvailable)
        }
    }
    func setMaintenanceState(_ options: AgentWikiMaintenanceOptions?, problem: String? = nil) {
        maintenanceAvailable = options != nil
        for (action, enabled) in [("auto-update", options?.autoUpdate), ("auto-export", options?.autoExport)] { let item = more.itemArray.first { $0.representedObject as? String == action }; item?.state = enabled == true ? .on : .off; item?.toolTip = problem }
    }
    func show(_ pages: [AgentWikiPage], selected: String?, root: String = ".bluefatfish/wiki") { self.pages = pages; selectedPath = selected; rootPath = root; rebuild() }
    private func rebuild() {
        applying = true; defer { applying = false }
        roots = []; nodes = [:]
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = pages.filter { query.isEmpty || ($0.title + "\n" + $0.path).range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        if pages.contains(where: { $0.parent != nil }) {
            let lookup = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }); var wanted = Set(filtered.map(\.path))
            for page in filtered { var parent = page.parent; while let path = parent, let value = lookup[path] { wanted.insert(path); parent = value.parent } }
            for page in pages where wanted.contains(page.path) { nodes[page.path] = Node(path: page.path, title: page.title, directory: false) }
            for page in pages where wanted.contains(page.path) { let node = nodes[page.path]!; if let path = page.parent, let parent = nodes[path] { parent.children.append(node); node.parent = parent } else { roots.append(node) } }
        } else { for page in filtered {
            let parts = page.path.dropFirst((rootPath + "/").count).split(separator: "/").map(String.init)
            var path = rootPath, parent: Node?
            for (index, part) in parts.enumerated() {
                path += "/" + part
                let node: Node
                if let existing = nodes[path] { node = existing }
                else {
                    let directory = index < parts.count - 1
                    node = Node(path: path, title: directory ? part : page.title, directory: directory); nodes[path] = node
                    if let parent { parent.children.append(node); node.parent = parent } else { roots.append(node) }
                }
                parent = node
            }
        } }
        func ordered(_ list: [Node]) -> [Node] {
            let sorted = list.sorted { a, b in
                let first = a.path == rootPath + "/index.md", second = b.path == rootPath + "/index.md"
                if first != second { return first }
                if a.directory != b.directory { return a.directory }
                let order = a.title.localizedStandardCompare(b.title); return order == .orderedSame ? a.path < b.path : order == .orderedAscending
            }
            for node in sorted { node.children = ordered(node.children) }; return sorted
        }
        roots = ordered(roots)
        let depth = nodes.values.map { node -> Int in var depth = 0, parent = node.parent; while let item = parent { depth += 1; parent = item.parent }; return depth }.max() ?? 0
        outline.outlineTableColumn?.width = max(165, CGFloat(depth) * 12 + 140)
        outline.reloadData()
        if !query.isEmpty { outline.expandItem(nil, expandChildren: true) }
        else { for path in expanded.sorted(by: { $0.count < $1.count }) { if let node = nodes[path] { outline.expandItem(node) } } }
        if let selectedPath, let node = nodes[selectedPath], outline.row(forItem: node) >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false) } else { outline.deselectAll(nil) }
        empty.stringValue = pages.isEmpty ? "暂无文档" : "无匹配文档"; empty.isHidden = !filtered.isEmpty
    }
    @discardableResult func select(_ path: String, notify: Bool = true) -> Bool {
        guard pages.contains(where: { $0.path == path }) else { return false }
        if nodes[path] == nil { search.stringValue = ""; rebuild() }
        guard let node = nodes[path], !node.directory, canSelect?(path) != false else { return false }
        applying = true
        var parent = node.parent, parents: [Node] = []
        while let item = parent { parents.append(item); parent = item.parent }
        for parent in parents.reversed() { outline.expandItem(parent); expanded.insert(parent.path) }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
        applying = false; selectedPath = path
        if notify { onSelect?(path) }; return row >= 0
    }
    @objc private func reloadCatalog() { onRefresh?() }
    @objc private func editPlan() { onPlan?() }
    @objc private func sharingAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { onSharing?(value) } }
    @objc private func changeLanguage() { let value = selectedLanguage; if onLanguage?(value) == false { return } }
    @objc private func toggleFolder() { guard outline.clickedRow >= 0 else { return }; if let node = outline.item(atRow: outline.clickedRow) as? Node, !node.children.isEmpty { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } } }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { guard let node = item as? Node else { return false }; return node.directory || applying || canSelect?(node.path) != false }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying, let node = outline.item(atRow: outline.selectedRow) as? Node, !node.directory else { return }
        selectedPath = node.path; onSelect?(node.path)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { if !applying, search.stringValue.isEmpty, let node = notification.userInfo?["NSObject"] as? Node { expanded.insert(node.path) } }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !applying, search.stringValue.isEmpty, let node = notification.userInfo?["NSObject"] as? Node { expanded.remove(node.path) } }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("wiki-node")
        let cell = outline.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier; let title = NSTextField(labelWithString: ""), image = NSImageView()
            title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingMiddle
            for child in [image, title] { cell.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 16), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.textField = title; cell.imageView = image
        }
        cell.textField?.stringValue = node.title; cell.imageView?.image = NSImage(systemSymbolName: node.directory ? "folder" : "doc.text", accessibilityDescription: node.directory ? "文件夹" : "文档")
        cell.toolTip = node.path; cell.setAccessibilityLabel(node.title + (node.directory ? "，文件夹" : "，文档")); return cell
    }
    var checkState: [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--wiki-tree-check") || CommandLine.arguments.contains("--wiki-plan-check") || CommandLine.arguments.contains("--repo-wiki-overview-check") else { return [:] }
        return ["language": selectedLanguage, "root": rootPath, "pages": pages.map { ["path": $0.path, "title": $0.title] }, "query": search.stringValue, "selected": selectedPath ?? "", "visible": (0..<outline.numberOfRows).compactMap { row -> [String: Any]? in guard let node = outline.item(atRow: row) as? Node else { return nil }; return ["path": node.path, "title": node.title, "directory": node.directory, "level": outline.level(forItem: node), "expanded": outline.isItemExpanded(node)] }, "emptyVisible": !empty.isHidden, "citationAvailable": citationAvailable, "citationEnabled": more.itemArray.first(where: { $0.representedObject as? String == "citation" })?.state == .on]
    }
}
