import AppKit

@MainActor final class AgentWikiTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    struct RecoveryState: Codable {
        var version = 1
        var workspace: String, branch: String, language: String, root: String, query: String
        var document: String?, row: String?, expanded: [String]
        var x: Double, y: Double
        var focus: String?, searchSelection: AgentTextViewport.Selection?

        var valid: Bool {
            func relative(_ path: String) -> Bool {
                !path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 8192 &&
                    !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            }
            func child(_ path: String) -> Bool { relative(path) && path.hasPrefix(root + "/") }
            return version == 1 && workspace.hasPrefix("/") && !workspace.contains("\0") && workspace.utf8.count <= 8192 &&
                URL(fileURLWithPath: workspace).standardizedFileURL.path == workspace &&
                !branch.isEmpty && branch.utf8.count <= 4096 && !branch.contains("\0") && ["zh", "en", "legacy"].contains(language) &&
                relative(root) && root.hasPrefix(".bluefatfish/") && query.utf8.count <= 100_000 &&
                document.map(child) != false && row.map(child) != false && expanded.count <= 10_000 && expanded.allSatisfy(child) &&
                [x, y].allSatisfy { $0.isFinite && (0...1_000_000_000).contains($0) } &&
                focus.map { ["search", "tree"].contains($0) } != false && searchSelection?.valid(in: (query as NSString).length) != false
        }
        static func validateObject(_ raw: Any) throws {
            guard let raw = raw as? [String: Any], Set(raw.keys).isSubset(of: ["version", "workspace", "branch", "language", "root", "query", "document", "row", "expanded", "x", "y", "focus", "searchSelection"]) else {
                throw PetError("Wiki 目录位置格式不受支持，原记录已保留")
            }
            if let selection = raw["searchSelection"], !(selection is NSNull) {
                guard let value = selection as? [String: Any], Set(value.keys).isSubset(of: ["location", "length"]) else { throw PetError("Wiki 搜索选区格式不受支持") }
            }
        }
    }
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
    private var pendingPosition: RecoveryState?, positionScheduled = false
    private var rootPath = ".bluefatfish/wiki"
    private let language = NSPopUpButton(), plan = NSButton(title: "规划", target: nil, action: nil), more = AgentWorkbenchButton(), sharing = NSMenu()
    private var citationAvailable = false
    private var maintenanceAvailable = false
    var canSelect: ((String) -> Bool)?, onSelect: ((String) -> Void)?, onRefresh: (() -> Void)?
    var onLanguage: ((String) -> Bool)?, onPlan: (() -> Void)?
    var onSharing: ((String) -> Void)?
    var onWorkspaceChange: (() -> Void)?
    var selectedLanguage: String { ["zh", "en", "legacy"][max(0, min(2, language.indexOfSelectedItem))] }
    var selectedDocument: String? { selectedPath }
    var preferredCompactHeight: CGFloat {
        let rows = CGFloat(min(6, max(2, pages.count)))
        return 78 + rows * (outline.rowHeight + outline.intercellSpacing.height)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "搜索 Wiki"; search.setAccessibilityLabel("搜索 Wiki 文档"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新 Wiki 目录"); refresh.bezelStyle = .texturedRounded; refresh.controlSize = .small; refresh.target = self; refresh.action = #selector(reloadCatalog); refresh.setAccessibilityLabel("刷新 Wiki 目录")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wiki")); column.width = 165; column.minWidth = 140; column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil; outline.rowHeight = 28; outline.indentationPerLevel = 12; outline.delegate = self; outline.dataSource = self; outline.setAccessibilityLabel("Wiki 文档树")
        outline.autoresizingMask = [.width]; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.target = self; outline.doubleAction = #selector(toggleFolder)
        outline.backgroundColor = .clear
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        empty.textColor = AgentWorkbenchTheme.secondaryText; empty.font = .systemFont(ofSize: 12); empty.setAccessibilityLabel("Wiki 目录状态")
        let toolbar = NSStackView(views: [search, refresh]); toolbar.spacing = 4
        language.addItems(withTitles: ["简体中文", "English", "旧版"]); language.controlSize = .small; language.target = self; language.action = #selector(changeLanguage); language.setAccessibilityLabel("Wiki 语言")
        plan.controlSize = .small; plan.bezelStyle = .texturedRounded; plan.target = self; plan.action = #selector(editPlan); plan.setAccessibilityLabel("Wiki 生成规划")
        plan.title = ""; plan.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil); plan.toolTip = "规划"; plan.widthAnchor.constraint(equalToConstant: 25).isActive = true
        AgentWorkbenchTheme.toolbar(more, title: "Wiki 更多操作", symbol: "ellipsis")
        more.target = self; more.action = #selector(showSharing); more.menu = sharing; sharing.autoenablesItems = false
        let groups = [
            [("增量更新…", "update"), ("重新生成 Wiki…", "regenerate")],
            [("导出项目知识", "knowledge-export"), ("从项目导入知识…", "knowledge-import"), ("恢复项目知识版本…", "knowledge-restore")],
            [("导出 Wiki 到项目", "export"), ("从项目导入 Wiki…", "import"), ("恢复 Wiki 版本…", "restore"), ("打开共享目录", "open")],
            [("自动引用 Wiki", "citation"), ("自动更新", "auto-update"), ("自动导出", "auto-export")]
        ]
        for group in groups {
            if !sharing.items.isEmpty { sharing.addItem(.separator()) }
            for (title, value) in group {
                let item = NSMenuItem(title: title, action: #selector(sharingAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = value; sharing.addItem(item)
            }
        }
        let options = NSStackView(views: [language, NSView(), plan, more]); options.spacing = 4
        for child in [toolbar, options, scroll, empty] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor), refresh.widthAnchor.constraint(equalToConstant: 25), options.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4), options.leadingAnchor.constraint(equalTo: leadingAnchor), options.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12)])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSTextView.didChangeSelectionNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); scheduleRecoveredPosition() }
    func captureRecovery(workspace: String, branch: String) throws -> RecoveryState {
        if let pendingPosition { return pendingPosition }
        let editor = search.currentEditor() as? NSTextView
        let focus = editor != nil && window?.firstResponder === editor ? "search" : window?.firstResponder === outline ? "tree" : nil
        let range = editor?.selectedRange()
        let row = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.path : nil
        let clip = scroll.contentView.bounds
        let state = RecoveryState(workspace: workspace, branch: branch, language: selectedLanguage, root: rootPath, query: search.stringValue,
                                  document: selectedPath, row: row, expanded: expanded.filter { $0.hasPrefix(rootPath + "/") }.sorted(), x: max(0, clip.minX), y: max(0, clip.minY),
                                  focus: focus, searchSelection: range.map { .init(location: $0.location, length: $0.length) })
        guard state.valid else { throw PetError("Wiki 目录位置无效，原记录已保留") }
        return state
    }
    func prepareRecovery(_ state: RecoveryState) {
        pendingPosition = state; setLanguage(state.language); search.stringValue = state.query
        expanded = Set(state.expanded); selectedPath = state.document
    }
    func scheduleRecoveredPosition() {
        guard pendingPosition != nil, !positionScheduled, !applying else { return }
        positionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { positionScheduled = false }
            guard let state = pendingPosition, state.root == rootPath, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
            applying = true; defer { applying = false }
            layoutSubtreeIfNeeded()
            if let node = state.row.flatMap({ self.nodes[$0] }), outline.row(forItem: node) >= 0 {
                outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
            } else { outline.deselectAll(nil) }
            if state.focus == "search" {
                window?.makeFirstResponder(search)
                if let selection = state.searchSelection { (search.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) }
            } else if state.focus == "tree" { window?.makeFirstResponder(outline) }
            let clip = scroll.contentView, proposed = NSRect(origin: NSPoint(x: state.x, y: state.y), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin); scroll.reflectScrolledClipView(clip)
            pendingPosition = nil; onWorkspaceChange?()
        }
    }
    @objc private func positionChanged(_ notification: Notification) {
        if let editor = notification.object as? NSTextView, (search.currentEditor() as? NSTextView) !== editor { return }
        if !applying, pendingPosition == nil { onWorkspaceChange?() }
    }
    func setLanguage(_ value: String) { language.selectItem(at: ["zh", "en", "legacy"].firstIndex(of: value) ?? 0) }
    func setCitationState(_ enabled: Bool?, problem: String? = nil) {
        citationAvailable = enabled != nil
        let item = sharing.items.first { $0.representedObject as? String == "citation" }
        item?.state = enabled == true ? .on : .off; item?.toolTip = problem
    }
    func setSharingState(busy: Bool, writable: Bool, canRegenerate: Bool = false) {
        language.isEnabled = !busy; more.isEnabled = !busy; plan.isEnabled = !busy
        for item in sharing.items where !item.isSeparatorItem {
            let action = item.representedObject as? String
            item.isEnabled = action == "citation" ? !busy && citationAvailable : !busy && selectedLanguage != "legacy" && (writable || action == "open") && (!["regenerate", "update"].contains(action ?? "") || canRegenerate) && (!["auto-update", "auto-export"].contains(action ?? "") || maintenanceAvailable)
        }
    }
    func setMaintenanceState(_ options: AgentWikiMaintenanceOptions?, problem: String? = nil) {
        maintenanceAvailable = options != nil
        for (action, enabled) in [("auto-update", options?.autoUpdate), ("auto-export", options?.autoExport)] { let item = sharing.items.first { $0.representedObject as? String == action }; item?.state = enabled == true ? .on : .off; item?.toolTip = problem }
    }
    func show(_ pages: [AgentWikiPage], selected: String?, root: String = ".bluefatfish/wiki") { self.pages = pages; selectedPath = selected; rootPath = root; rebuild(); scheduleRecoveredPosition() }
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
        outline.outlineTableColumn?.minWidth = CGFloat(depth) * 12 + 140
        outline.sizeToFit()
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
    @objc private func showSharing() { sharing.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more) }
    @objc private func sharingAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { onSharing?(value) } }
    @objc private func changeLanguage() { let value = selectedLanguage; if onLanguage?(value) == false { return } }
    @objc private func toggleFolder() { guard outline.clickedRow >= 0 else { return }; if let node = outline.item(atRow: outline.clickedRow) as? Node, !node.children.isEmpty { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } } }
    func controlTextDidChange(_ obj: Notification) { pendingPosition = nil; rebuild(); onWorkspaceChange?() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { guard let node = item as? Node else { return false }; return node.directory || applying || canSelect?(node.path) != false }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        defer { onWorkspaceChange?() }
        if outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? Node, !node.directory {
            selectedPath = node.path; onSelect?(node.path)
        }
    }
    func outlineViewItemDidExpand(_ notification: Notification) { if !applying, search.stringValue.isEmpty, let node = notification.userInfo?["NSObject"] as? Node { expanded.insert(node.path); onWorkspaceChange?() } }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !applying, search.stringValue.isEmpty, let node = notification.userInfo?["NSObject"] as? Node { expanded.remove(node.path); onWorkspaceChange?() } }
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
        cell.textField?.stringValue = node.title
        if let image = cell.imageView {
            if node.directory { AgentFileIcons.unbind(image); image.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹") }
            else { AgentFileIcons.bind(image, filename: node.path) }
        }
        cell.toolTip = node.path; cell.setAccessibilityLabel(node.title + (node.directory ? "，文件夹" : "，文档")); return cell
    }
    var checkState: [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--wiki-tree-check") || CommandLine.arguments.contains("--wiki-plan-check") || CommandLine.arguments.contains("--repo-wiki-overview-check") else { return [:] }
        return ["language": selectedLanguage, "root": rootPath, "pages": pages.map { ["path": $0.path, "title": $0.title] }, "query": search.stringValue, "selected": selectedPath ?? "", "visible": (0..<outline.numberOfRows).compactMap { row -> [String: Any]? in guard let node = outline.item(atRow: row) as? Node else { return nil }; return ["path": node.path, "title": node.title, "directory": node.directory, "level": outline.level(forItem: node), "expanded": outline.isItemExpanded(node)] }, "emptyVisible": !empty.isHidden, "citationAvailable": citationAvailable, "citationEnabled": sharing.items.first(where: { $0.representedObject as? String == "citation" })?.state == .on]
    }
}
