import AppKit

@MainActor final class AgentWikiTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private final class Node: NSObject {
        let path: String, title: String, directory: Bool
        var children: [Node] = []
        init(path: String, title: String, directory: Bool) { self.path = path; self.title = title; self.directory = directory; super.init() }
    }
    private let search = NSSearchField(), refresh = NSButton(), outline = NSOutlineView(), scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "暂无文档")
    private var pages: [AgentWikiPage] = [], roots: [Node] = [], nodes: [String: Node] = [:], expanded: Set<String> = []
    private var applying = false, selectedPath: String?
    var canSelect: ((String) -> Bool)?, onSelect: ((String) -> Void)?, onRefresh: (() -> Void)?
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
        empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 12); empty.setAccessibilityLabel("Wiki 目录状态")
        let toolbar = NSStackView(views: [search, refresh]); toolbar.spacing = 4
        for child in [toolbar, scroll, empty] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor), refresh.widthAnchor.constraint(equalToConstant: 25), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ pages: [AgentWikiPage], selected: String?) { self.pages = pages; selectedPath = selected; rebuild() }
    private func rebuild() {
        applying = true; defer { applying = false }
        roots = []; nodes = [:]
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = pages.filter { query.isEmpty || ($0.title + "\n" + $0.path).range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        for page in filtered {
            let parts = page.path.dropFirst(".bluefatfish/wiki/".count).split(separator: "/").map(String.init)
            var path = ".bluefatfish/wiki", parent: Node?
            for (index, part) in parts.enumerated() {
                path += "/" + part
                let node: Node
                if let existing = nodes[path] { node = existing }
                else {
                    let directory = index < parts.count - 1
                    node = Node(path: path, title: directory ? part : page.title, directory: directory); nodes[path] = node
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                }
                parent = node
            }
        }
        func ordered(_ list: [Node]) -> [Node] {
            let sorted = list.sorted { a, b in
                let first = a.path == ".bluefatfish/wiki/index.md", second = b.path == ".bluefatfish/wiki/index.md"
                if first != second { return first }
                if a.directory != b.directory { return a.directory }
                let order = a.title.localizedStandardCompare(b.title); return order == .orderedSame ? a.path < b.path : order == .orderedAscending
            }
            for node in sorted { node.children = ordered(node.children) }; return sorted
        }
        roots = ordered(roots)
        let depth = nodes.values.map { $0.path.split(separator: "/").count - 3 }.max() ?? 0
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
        var parent = (path as NSString).deletingLastPathComponent, parents: [String] = []
        while parent.hasPrefix(".bluefatfish/wiki/") { parents.append(parent); parent = (parent as NSString).deletingLastPathComponent }
        for parent in parents.reversed() { if let item = nodes[parent] { outline.expandItem(item); expanded.insert(parent) } }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
        applying = false; selectedPath = path
        if notify { onSelect?(path) }; return row >= 0
    }
    @objc private func reloadCatalog() { onRefresh?() }
    @objc private func toggleFolder() { if let node = outline.item(atRow: outline.clickedRow) as? Node, node.directory { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } } }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.directory == true }
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
        guard CommandLine.arguments.contains("--wiki-tree-check") else { return [:] }
        return ["pages": pages.map { ["path": $0.path, "title": $0.title] }, "query": search.stringValue, "selected": selectedPath ?? "", "visible": (0..<outline.numberOfRows).compactMap { row -> [String: Any]? in guard let node = outline.item(atRow: row) as? Node else { return nil }; return ["path": node.path, "title": node.title, "directory": node.directory, "level": outline.level(forItem: node), "expanded": outline.isItemExpanded(node)] }, "emptyVisible": !empty.isHidden]
    }
}
