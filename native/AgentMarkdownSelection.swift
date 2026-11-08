import AppKit

struct AgentMarkdownSelection {
    let file: URL, workspace: String, text: String
    var draftText: String {
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path + "/", canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        let path = canonical.path.hasPrefix(root) ? String(canonical.path.dropFirst(root.count)) : canonical.lastPathComponent
        return "[文件选文：" + path.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "]\n" + text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }
}

@MainActor final class AgentMarkdownTextView: NSTextView {
    var onSelectionSettled: (() -> Void)?
    var onDoubleClickAttachment: ((Int) -> Bool)?
    // NSTextView tracks selection inside mouseDown and consumes mouseUp.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let layout = layoutManager, let container = textContainer, let storage = textStorage {
            let local = convert(event.locationInWindow, from: nil), point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: point, in: container)
            if glyph < layout.numberOfGlyphs {
                let character = layout.characterIndexForGlyph(at: glyph), rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                if character < storage.length, rect.contains(point), storage.attribute(.attachment, at: character, effectiveRange: nil) != nil, onDoubleClickAttachment?(character) == true { return }
            }
        }
        super.mouseDown(with: event)
        let range = selectedRange()
        if event.clickCount > 1, range.length == 1, let storage = textStorage, range.location < storage.length, storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil { return }
        onSelectionSettled?()
    }
    override func keyUp(with event: NSEvent) { super.keyUp(with: event); onSelectionSettled?() }
}

// Shared by preview and source views; the quoted text is a snapshot of the
// visible selection, including unsaved edits. Adding never sends a message.
@MainActor final class AgentMarkdownSelectionAction: NSObject {
    private let text: AgentMarkdownTextView, button: NSButton, context: () -> (URL, String)?
    private var popover: NSPopover?
    var onAdd: ((AgentMarkdownSelection) throws -> Void)? { didSet { update() } }
    var canAdd: (() -> Bool)? { didSet { update() } }
    init(text: AgentMarkdownTextView, button: NSButton, context: @escaping () -> (URL, String)?) {
        self.text = text; self.button = button; self.context = context; super.init()
        button.target = self; button.action = #selector(add); button.bezelStyle = .texturedRounded; button.controlSize = .small
        button.setAccessibilityLabel("选文加入任务")
        text.onSelectionSettled = { [weak self] in self?.present() }; update()
    }
    func update() {
        popover?.close(); popover = nil
        button.isHidden = onAdd == nil || context() == nil; button.isEnabled = onAdd != nil && canAdd?() != false && context() != nil && text.selectedRanges.count == 1 && text.selectedRange().length > 0
    }
    func selection() throws -> AgentMarkdownSelection {
        guard let (file, workspace) = context(), text.selectedRanges.count == 1, let storage = text.textStorage else { throw PetError("请先选择一段文字") }
        let range = text.selectedRange()
        guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= storage.length else { throw PetError("请先选择一段文字") }
        let value = storage.attributedSubstring(from: range), selected = NSMutableString(string: value.string)
        var replacements: [(NSRange, String)] = []
        value.enumerateAttribute(AgentMarkdownDocument.selectedSource, in: NSRange(location: 0, length: value.length)) { source, range, _ in if let source = source as? String { replacements.append((range, source)) } }
        for (range, source) in replacements.reversed() { selected.replaceCharacters(in: range, with: source) }
        let result = selected as String
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.utf8.count <= 16_384 else { throw PetError("请选择不超过 16KB 的文字") }
        return AgentMarkdownSelection(file: file, workspace: workspace, text: result)
    }
    private func present() {
        update()
        guard button.isEnabled, let layout = text.layoutManager, let container = text.textContainer, text.window?.isVisible == true else { return }
        let glyphs = layout.glyphRange(forCharacterRange: text.selectedRange(), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y).intersection(text.visibleRect)
        guard !rect.isNull else { return }; let anchorHeight = min(24, rect.height); rect.origin.y = rect.maxY - anchorHeight; rect.size.height = anchorHeight
        let add = NSButton(title: "加入任务", target: self, action: #selector(add)); add.bezelStyle = .rounded; add.setAccessibilityLabel("浮动选文加入任务")
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 108, height: 42)); add.frame = NSRect(x: 10, y: 7, width: 88, height: 28); controller.view.addSubview(add)
        let popup = NSPopover(); popup.behavior = .semitransient; popup.animates = false; popup.contentViewController = controller; popover = popup
        popup.show(relativeTo: rect, of: text, preferredEdge: .maxY)
    }
    @objc private func add() {
        do {
            guard let onAdd, canAdd?() != false else { throw PetError("此任务不能接收选文") }
            let selected = try selection(); popover?.close(); popover = nil; try onAdd(selected)
        } catch {
            let alert = NSAlert(); alert.messageText = error.localizedDescription
            if let window = text.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }
}
