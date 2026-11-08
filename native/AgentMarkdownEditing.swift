import AppKit

enum AgentMarkdownEditing {
    struct Line {
        let text: String, range: NSRange, fullRange: NSRange
    }
    struct Cell { let text: String; let range: NSRange }
    struct Region {
        enum Kind: Equatable { case block; case cell(table: Int, row: Int, column: Int) }
        let source: NSRange, display: NSRange, kind: Kind
        var prefix = "", suffix = ""
        var isCell: Bool { if case .cell = kind { return true }; return false }
    }
    static func lines(_ source: String) -> [Line] {
        let text = source as NSString
        var result: [Line] = [], cursor = 0, trailing = false
        while cursor < text.length {
            var start = 0, end = 0, contentEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            let contentStart = start == 0 && text.character(at: 0) == 0xFEFF ? 1 : start
            let range = NSRange(location: contentStart, length: contentEnd - contentStart)
            result.append(Line(text: text.substring(with: range), range: range, fullRange: NSRange(location: start, length: end - start)))
            cursor = end; trailing = contentEnd < end
        }
        if result.isEmpty || trailing { result.append(Line(text: "", range: NSRange(location: text.length, length: 0), fullRange: NSRange(location: text.length, length: 0))) }
        return result
    }
    static func cells(_ line: String) -> [Cell] {
        var ranges: [NSRange] = [], start = line.startIndex, cursor = start, code = 0
        while cursor < line.endIndex {
            let position = cursor, char = line[cursor]; cursor = line.index(after: cursor)
            if char == "\\", cursor < line.endIndex { cursor = line.index(after: cursor); continue }
            if char == "`" {
                let remaining = line[cursor...].prefix(while: { $0 == "`" }).count, count = remaining + 1
                cursor = line.index(cursor, offsetBy: remaining)
                if code == 0 { code = count } else if code == count { code = 0 }
            }
            if char == "|", code == 0 { ranges.append(NSRange(start..<position, in: line)); start = cursor }
        }
        ranges.append(NSRange(start..<line.endIndex, in: line))
        let text = line as NSString
        if ranges.count > 1, text.substring(with: ranges[0]).trimmingCharacters(in: .whitespaces).isEmpty { ranges.removeFirst() }
        if !ranges.isEmpty, line.contains("|"), text.substring(with: ranges.last!).trimmingCharacters(in: .whitespaces).isEmpty { ranges.removeLast() }
        return ranges.map { span in
            let raw = text.substring(with: span), trimmed = raw.trimmingCharacters(in: .whitespaces)
            let local: NSRange
            if trimmed.isEmpty { local = NSRange(location: min(1, span.length), length: 0) }
            else { local = (raw as NSString).range(of: trimmed) }
            return Cell(text: trimmed.replacingOccurrences(of: "\\|", with: "|"), range: NSRange(location: span.location + local.location, length: local.length))
        }
    }
    static func missingCell(_ line: Line, column: Int, existing: Int, display: NSRange, table: Int, row: Int) -> Region {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces), trailing = trimmed.hasSuffix("|")
        let end = (line.text as NSString).length - (line.text as NSString).range(of: trimmed).location - (trimmed as NSString).length
        let location = line.range.location + (line.text as NSString).length - max(0, end) - (trailing ? 1 : 0)
        return Region(source: NSRange(location: max(line.range.location, location), length: 0), display: display, kind: .cell(table: table, row: row, column: column), prefix: (trailing ? "" : " ") + String(repeating: "| ", count: max(1, column - existing + 1)), suffix: trailing ? " " : "")
    }
    static func value(_ region: Region, in source: String) throws -> String {
        let count = (source as NSString).length
        guard region.source.location >= 0, region.source.length >= 0, region.source.location <= count, region.source.length <= count - region.source.location else { throw PetError("文档位置已变化，请重新选择编辑位置") }
        guard let range = Range(region.source, in: source) else { throw PetError("文档位置已变化，请重新选择编辑位置") }
        let raw = String(source[range])
        return region.isCell ? raw.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]) : raw
    }
    static func replacing(_ region: Region, in source: String, with value: String) throws -> String {
        guard !value.contains("\0"), value.utf8.count <= 2_000_000 else { throw PetError("文字包含空字符或超过 2MB，请缩减后重试，或按 Esc 取消本次修改") }
        _ = try self.value(region, in: source)
        guard let range = Range(region.source, in: source) else { throw PetError("文档位置已变化，请重新选择编辑位置") }
        if value == (try self.value(region, in: source)) { return source }
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let replacement: String
        if region.isCell {
            var encoded = "", slashes = 0
            for char in normalized.replacingOccurrences(of: "\n", with: "<br>") {
                if char == "|", slashes % 2 == 0 { encoded.append("\\") }
                encoded.append(char); slashes = char == "\\" ? slashes + 1 : 0
            }
            replacement = region.prefix + encoded + region.suffix
        } else {
            let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
            replacement = region.prefix + normalized.replacingOccurrences(of: "\n", with: newline) + region.suffix
        }
        let result = source.replacingCharacters(in: range, with: replacement)
        guard result.utf8.count <= 2_000_000 else { throw PetError("文档超过 2MB，请缩减本次修改") }
        return result
    }
}

@MainActor private final class AgentMarkdownUnitTextView: NSTextView {
    let edits = UndoManager()
    var onCommand: ((Selector) -> Bool)?
    override var undoManager: UndoManager? { edits }
    @objc func undo(_ sender: Any?) { if edits.canUndo { edits.undo() } }
    @objc func redo(_ sender: Any?) { if edits.canRedo { edits.redo() } }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return edits.canUndo }
        if item.action == #selector(redo(_:)) { return edits.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommand?(#selector(NSResponder.insertNewline(_:))); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func doCommand(by selector: Selector) { if onCommand?(selector) != true { super.doCommand(by: selector) } }
}

// The active block reveals its Markdown in place; surrounding blocks remain
// rendered. Patches replace only the exact original source span, never an
// attributed-string serialization of the rest of the document.
@MainActor final class AgentMarkdownInlineEditor: NSScrollView, NSTextViewDelegate {
    private let field = AgentMarkdownUnitTextView()
    let region: AgentMarkdownEditing.Region, base: String
    var onChange: ((String) -> Void)?, onFinish: ((Bool, Int) -> Void)?
    var value: String { field.string }
    init(region: AgentMarkdownEditing.Region, source: String) throws {
        self.region = region; base = source; super.init(frame: .zero)
        field.string = try AgentMarkdownEditing.value(region, in: source)
        field.isRichText = false; field.isEditable = true; field.isSelectable = true; field.allowsUndo = true; field.edits.levelsOfUndo = 100
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular); field.textColor = .labelColor; field.backgroundColor = .textBackgroundColor
        field.isAutomaticQuoteSubstitutionEnabled = false; field.isAutomaticTextReplacementEnabled = false; field.isAutomaticSpellingCorrectionEnabled = false
        field.textContainerInset = NSSize(width: 6, height: 4); field.isVerticallyResizable = true; field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true; field.delegate = self
        field.setAccessibilityLabel(region.isCell ? "Markdown 单元格编辑" : "Markdown 正文编辑")
        field.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) { onFinish?(false, 0); return true }
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true { onFinish?(true, 0); return true }
            if region.isCell, [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))].contains(selector) { onFinish?(true, selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1); return true }
            return false
        }
        documentView = field; hasVerticalScroller = true; drawsBackground = true; borderType = .lineBorder
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func focus() { window?.makeFirstResponder(field); field.setSelectedRange(region.isCell ? NSRange(location: 0, length: (field.string as NSString).length) : NSRange(location: (field.string as NSString).length, length: 0)) }
    func textDidChange(_ notification: Notification) { onChange?(field.string) }
    func undoManager(for view: NSTextView) -> UndoManager? { field.edits }
    func commitInput() { field.unmarkText(); field.inputContext?.discardMarkedText() }
}
