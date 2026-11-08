import AppKit

struct AgentGitDiffLine {
    enum Kind: Equatable { case context, removed, added, metadata, empty }
    var number: Int?; var text: String; var kind: Kind; var noNewline = false
}
struct AgentGitDiffRow { var old: AgentGitDiffLine; var new: AgentGitDiffLine }

enum AgentGitDiffRows {
    static func parse(_ patch: String) -> [AgentGitDiffRow] {
        let empty = AgentGitDiffLine(text: "", kind: .empty)
        var rows: [AgentGitDiffRow] = [], removed: [AgentGitDiffLine] = [], added: [AgentGitDiffLine] = []
        var old = 0, new = 0, inHunk = false, binary = false, fileHeader: Int?, oldPath: String?
        func flush() {
            for index in 0..<max(removed.count, added.count) { rows.append(AgentGitDiffRow(old: index < removed.count ? removed[index] : empty, new: index < added.count ? added[index] : empty)) }
            removed.removeAll(keepingCapacity: true); added.removeAll(keepingCapacity: true)
        }
        // Swift treats CRLF as one Character. Split at the LF code unit and
        // retain CR as file content, including the final patch record.
        for raw in patch.components(separatedBy: "\n").dropLast(patch.utf8.last == 10 ? 1 : 0) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush(); inHunk = false; binary = false; oldPath = nil; fileHeader = rows.count
                let item = AgentGitDiffLine(text: String(line.dropFirst(11)), kind: .metadata)
                rows.append(AgentGitDiffRow(old: item, new: item)); continue
            }
            if binary { continue }
            if !inHunk, line.hasPrefix("index ") { continue }
            if !inHunk, line.hasPrefix("--- ") { oldPath = String(line.dropFirst(4)); continue }
            if !inHunk, line.hasPrefix("+++ ") {
                let pair = AgentGitDiffRow(old: AgentGitDiffLine(text: oldPath ?? "", kind: .metadata), new: AgentGitDiffLine(text: String(line.dropFirst(4)), kind: .metadata))
                if let fileHeader { rows[fileHeader] = pair } else { rows.append(pair) }
                continue
            }
            if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                flush(); let item = AgentGitDiffLine(text: "二进制文件已更改", kind: .metadata)
                rows.append(AgentGitDiffRow(old: item, new: item)); binary = true; inHunk = false; continue
            }
            if line.hasPrefix("@@ "), let match = line.range(of: "^@@ -[0-9]+(,[0-9]+)? \\+[0-9]+(,[0-9]+)? @@", options: .regularExpression) {
                flush(); let pieces = line[match].split(separator: " ")
                old = Int(pieces[1].dropFirst().split(separator: ",")[0]) ?? 0; new = Int(pieces[2].dropFirst().split(separator: ",")[0]) ?? 0; inHunk = true
                let item = AgentGitDiffLine(text: line, kind: .metadata); rows.append(AgentGitDiffRow(old: item, new: item)); continue
            }
            if inHunk, line.hasPrefix("-") { removed.append(AgentGitDiffLine(number: old, text: String(line.dropFirst()), kind: .removed)); old += 1; continue }
            if inHunk, line.hasPrefix("+") { added.append(AgentGitDiffLine(number: new, text: String(line.dropFirst()), kind: .added)); new += 1; continue }
            if inHunk, line == "\\ No newline at end of file" {
                if !added.isEmpty { added[added.count - 1].noNewline = true }
                else if !removed.isEmpty { removed[removed.count - 1].noNewline = true }
                else if let last = rows.indices.last { rows[last].old.noNewline = true; rows[last].new.noNewline = true }
                continue
            }
            flush()
            if inHunk, line.hasPrefix(" ") {
                rows.append(AgentGitDiffRow(old: AgentGitDiffLine(number: old, text: String(line.dropFirst()), kind: .context), new: AgentGitDiffLine(number: new, text: String(line.dropFirst()), kind: .context))); old += 1; new += 1
            } else {
                let item = AgentGitDiffLine(text: line, kind: .metadata); rows.append(AgentGitDiffRow(old: item, new: item))
            }
        }
        flush(); return rows
    }
}

@MainActor final class AgentGitDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let text = NSTextView()
    private let unified = NSScrollView(), oldScroll = NSScrollView(), newScroll = NSScrollView(), split = NSView()
    private let oldTable = NSTableView(), newTable = NSTableView(), measuringCell = NSTextFieldCell(textCell: ""), font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var rows: [AgentGitDiffRow] = [], heights: [Int: CGFloat] = [:], widths = NSSize.zero, longest = NSSize.zero, synchronizing = false
    var splitMode = false { didSet { unified.isHidden = splitMode; split.isHidden = !splitMode; needsLayout = true } }
    var wraps = true { didSet { widths = .zero; heights.removeAll(); configureUnified(); needsLayout = true } }
    var patch: String { text.string }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        measuringCell.font = font; measuringCell.wraps = true; measuringCell.isScrollable = false; measuringCell.usesSingleLineMode = false; measuringCell.lineBreakMode = .byCharWrapping
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = font; text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.backgroundColor = .white; text.setAccessibilityLabel("Git 实际差异")
        unified.documentView = text; unified.hasVerticalScroller = true
        for (table, scroll, title) in [(oldTable, oldScroll, "旧版本"), (newTable, newScroll, "新版本")] {
            let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("number")); number.title = ""; number.width = 44; number.resizingMask = []
            let line = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line")); line.title = title; line.resizingMask = []
            table.addTableColumn(number); table.addTableColumn(line); table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 23)); table.delegate = self; table.dataSource = self
            table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsColumnReordering = false; table.intercellSpacing = .zero; table.selectionHighlightStyle = .none
            table.style = .plain; table.backgroundColor = .white
            table.setAccessibilityLabel("Git " + title + "差异"); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            split.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: split.topAnchor), scroll.bottomAnchor.constraint(equalTo: split.bottomAnchor)])
        }
        NSLayoutConstraint.activate([oldScroll.leadingAnchor.constraint(equalTo: split.leadingAnchor), newScroll.leadingAnchor.constraint(equalTo: oldScroll.trailingAnchor, constant: 1), newScroll.trailingAnchor.constraint(equalTo: split.trailingAnchor), oldScroll.widthAnchor.constraint(equalTo: newScroll.widthAnchor)])
        for view in [unified, split] {
            addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor), view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        split.isHidden = true; configureUnified()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func display(_ line: String) -> String { line.replacingOccurrences(of: "\r", with: "␍") }
    func show(_ patch: String, oldTitle: String, newTitle: String, accessibilityContext: String = "Git") {
        let content = NSMutableAttributedString(string: patch, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        var offset = 0, inHunk = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { inHunk = false }; if line.hasPrefix("@@") { inHunk = true }
            let color: NSColor = inHunk && line.hasPrefix("+") ? .systemGreen : inHunk && line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") || line.hasPrefix("diff --git ") ? .secondaryLabelColor : .labelColor
            content.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset, length: (line as NSString).length)); offset += (line as NSString).length + 1
        }
        text.textStorage?.setAttributedString(content); rows = AgentGitDiffRows.parse(patch); heights.removeAll(); widths = .zero
        oldTable.tableColumns[1].title = oldTitle; newTable.tableColumns[1].title = newTitle
        text.setAccessibilityLabel(accessibilityContext + " 实际差异")
        oldTable.setAccessibilityLabel(accessibilityContext + " " + oldTitle + "差异"); newTable.setAccessibilityLabel(accessibilityContext + " " + newTitle + "差异")
        longest = NSSize(width: rows.map { (display($0.old.text) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0, height: rows.map { (display($0.new.text) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        oldTable.reloadData(); newTable.reloadData(); configureUnified(); needsLayout = true
    }
    private func configureUnified() {
        text.isHorizontallyResizable = !wraps; text.autoresizingMask = wraps ? [.width] : []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let targetWidth = wraps ? max(1, unified.contentSize.width) : max(unified.contentSize.width, max(longest.width, longest.height) + 80)
        if abs(text.frame.width - targetWidth) > 0.5 { text.setFrameSize(NSSize(width: targetWidth, height: text.frame.height)) }
        text.textContainer?.widthTracksTextView = wraps
        text.textContainer?.containerSize = NSSize(width: wraps ? max(1, unified.contentSize.width - 24) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        unified.hasHorizontalScroller = !wraps
        if let container = text.textContainer, let manager = text.layoutManager {
            manager.ensureLayout(for: container)
            let height = max(unified.contentSize.height, ceil(manager.usedRect(for: container).height) + text.textContainerInset.height * 2)
            if abs(text.frame.height - height) > 0.5 { text.setFrameSize(NSSize(width: targetWidth, height: height)) }
        }
    }
    override func layout() {
        super.layout(); configureUnified()
        let next = NSSize(width: oldScroll.contentSize.width, height: newScroll.contentSize.width)
        guard widths != next else { return }; widths = next; heights.removeAll()
        let previousY = oldScroll.contentView.bounds.origin.y
        synchronizing = true
        NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0
        for (table, available, length) in [(oldTable, next.width, longest.width), (newTable, next.height, longest.height)] {
            table.tableColumns[1].width = wraps ? max(50, available - 44) : max(max(50, available - 44), length + 12)
            table.setFrameOrigin(.zero); table.setFrameSize(NSSize(width: 44 + table.tableColumns[1].width, height: table.frame.height)); table.reloadData()
            if !rows.isEmpty { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
            table.sizeToFit(); table.layoutSubtreeIfNeeded()
        }
        NSAnimationContext.endGrouping()
        let maximumY = max(0, min(oldTable.bounds.height - oldScroll.contentSize.height, newTable.bounds.height - newScroll.contentSize.height)), y = max(0, min(previousY, maximumY))
        for scroll in [oldScroll, newScroll] { scroll.contentView.scroll(to: NSPoint(x: wraps ? 0 : scroll.contentView.bounds.origin.x, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        synchronizing = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let value = heights[row] { return value }
        guard wraps, rows.indices.contains(row) else { return 20 }
        let values = [(rows[row].old, max(1, widths.width - 56)), (rows[row].new, max(1, widths.height - 56))]
        let height = values.map { line, width in
            let string = display(line.text); measuringCell.stringValue = string.isEmpty ? " " : string
            return measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)).height
        }.max() ?? 16
        let result = max(20, ceil(height) + 4); heights[row] = result; return result
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let item = tableView === oldTable ? rows[row].old : rows[row].new, number = tableColumn.identifier.rawValue == "number"
        let identifier = NSUserInterfaceItemIdentifier(number ? "number" : wraps ? "wrapped" : "single")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView(); view.identifier = identifier
            let field = NSTextField(labelWithString: ""); field.font = font; field.isSelectable = !number; field.maximumNumberOfLines = number || !wraps ? 1 : 0; field.cell?.wraps = !number && wraps; field.usesSingleLineMode = number || !wraps; field.lineBreakMode = wraps && !number ? .byCharWrapping : .byClipping
            view.addSubview(field); view.textField = field; field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6), field.topAnchor.constraint(equalTo: view.topAnchor, constant: 2)])
            return view
        }()
        cell.textField?.stringValue = number ? item.number.map(String.init) ?? "" : display(item.text)
        cell.textField?.preferredMaxLayoutWidth = !number && wraps ? max(1, tableColumn.width - 12) : 0
        cell.textField?.toolTip = item.noNewline ? "无行尾换行" : nil
        cell.textField?.textColor = number || item.kind == .metadata ? .secondaryLabelColor : .labelColor
        cell.textField?.alignment = number ? .right : .left
        cell.wantsLayer = true; cell.layer?.backgroundColor = (item.kind == .removed ? NSColor(calibratedRed: 0.99, green: 0.92, blue: 0.92, alpha: 1) : item.kind == .added ? NSColor(calibratedRed: 0.92, green: 0.97, blue: 0.93, alpha: 1) : item.kind == .empty ? NSColor(white: 0.96, alpha: 1) : NSColor.white).cgColor
        return cell
    }
    @objc private func scrolled(_ notification: Notification) {
        if abs(widths.width - oldScroll.contentSize.width) > 0.5 || abs(widths.height - newScroll.contentSize.width) > 0.5 { needsLayout = true }
        guard splitMode, !synchronizing, let clip = notification.object as? NSClipView else { return }
        let other = clip === oldScroll.contentView ? newScroll : oldScroll
        synchronizing = true; other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: clip.bounds.origin.y)); other.reflectScrolledClipView(other.contentView); synchronizing = false
    }
    func checkSplitLayout() -> [String: Bool] {
        splitMode = true; layoutSubtreeIfNeeded()
        let rowsAlign = !rows.isEmpty && rows.indices.allSatisfy { abs(oldTable.rect(ofRow: $0).minY - newTable.rect(ofRow: $0).minY) < 1 && abs(oldTable.rect(ofRow: $0).height - newTable.rect(ofRow: $0).height) < 1 }
        let reflowAligned = !rows.isEmpty && rows.indices.allSatisfy { abs(oldTable.convert(oldTable.rect(ofRow: $0).origin, to: self).y - newTable.convert(newTable.rect(ofRow: $0).origin, to: self).y) < 1 }
        oldScroll.contentView.scroll(to: NSPoint(x: 0, y: min(80, max(0, oldTable.bounds.height - oldScroll.contentSize.height)))); oldScroll.reflectScrolledClipView(oldScroll.contentView)
        return ["splitDiffRowsAlign": rowsAlign, "splitDiffReflowKeepsRowsAligned": reflowAligned, "splitDiffVerticalScrollStaysAligned": abs(oldScroll.contentView.bounds.minY - newScroll.contentView.bounds.minY) < 1, "splitDiffBothSidesVisible": oldScroll.bounds.width > 150 && newScroll.bounds.width > 150, "unifiedWrapFitsViewport": !wraps || text.frame.width <= unified.contentSize.width + 1]
    }
}
