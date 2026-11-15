import AppKit

struct AgentTextViewport: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        var location: Int, length: Int
        var range: NSRange { NSRange(location: location, length: length) }
        func valid(in count: Int) -> Bool { location >= 0 && length >= 0 && location <= count && length <= count - location }
    }
    var version = 1
    var hash: String
    var count: Int
    var selections: [Selection]
    var x: Double, y: Double
    var anchor: Int, offset: Double
    var focused: Bool
    var valid: Bool {
        version == 1 && hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase } &&
        (0...20_000_000).contains(count) && (1...256).contains(selections.count) && selections.allSatisfy { $0.valid(in: count) } &&
        [x, y].allSatisfy { $0.isFinite && (0...1_000_000_000).contains($0) } &&
        (0...count).contains(anchor) && offset.isFinite && abs(offset) <= 1_000_000_000
    }
    static func validateObject(_ raw: Any) throws {
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["version", "hash", "count", "selections", "x", "y", "anchor", "offset", "focused"]),
              let selections = value["selections"] as? [[String: Any]], selections.allSatisfy({ Set($0.keys).isSubset(of: ["location", "length"]) }) else { throw PetError("文本位置恢复格式不受支持，原记录已保留") }
    }
    @MainActor init(_ text: NSTextView) throws {
        hash = AgentFiles.hash(Data(text.string.utf8)); count = (text.string as NSString).length
        selections = text.selectedRanges.map { .init(location: $0.rangeValue.location, length: $0.rangeValue.length) }
        let clip = text.enclosingScrollView?.contentView
        x = max(0, clip?.bounds.minX ?? 0); y = max(0, clip?.bounds.minY ?? 0)
        anchor = 0; offset = y
        focused = text.window?.firstResponder === text
        if count > 0, let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            if layout.numberOfGlyphs > 0 {
                let point = NSPoint(x: max(0, x - text.textContainerOrigin.x), y: max(0, y - text.textContainerOrigin.y))
                let glyph = min(layout.numberOfGlyphs - 1, layout.glyphIndex(for: point, in: container))
                anchor = layout.characterIndexForGlyph(at: glyph)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                offset = y - rect.minY - text.textContainerOrigin.y
            }
        }
        guard valid else { throw PetError("文本位置或选区无效，原记录已保留") }
    }
    @MainActor func matches(_ text: NSTextView) -> Bool {
        valid && count == (text.string as NSString).length && hash == AgentFiles.hash(Data(text.string.utf8))
    }
    @MainActor @discardableResult func apply(to text: NSTextView, focus: Bool = true) -> Bool {
        guard matches(text), let scroll = text.enclosingScrollView, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return false }
        if focus, focused, !text.isHiddenOrHasHiddenAncestor { text.window?.makeFirstResponder(text) }
        text.setSelectedRanges(selections.map { NSValue(range: $0.range) }, affinity: .downstream, stillSelecting: false)
        var targetY = y
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)
            text.setFrameSize(NSSize(width: text.frame.width, height: height))
            if count > 0, layout.numberOfGlyphs > 0 {
                let glyph = min(layout.numberOfGlyphs - 1, layout.glyphIndexForCharacter(at: min(anchor, count - 1)))
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                targetY = max(0, rect.minY + text.textContainerOrigin.y + offset)
            }
        }
        scroll.contentView.scroll(to: NSPoint(x: x, y: targetY)); scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
}
