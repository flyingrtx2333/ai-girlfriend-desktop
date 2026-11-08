import AppKit

@MainActor enum NativeMarkdown {
    static func render(_ source: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle, resolveLink: ((URL) -> URL?)? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString(), lines = source.components(separatedBy: "\n")
        var code = false, tableColumns = 0, renderedLines = 0
        for (index, original) in lines.enumerated() {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { code.toggle(); continue }
            if !code, isTableDivider(original) { continue }
            if renderedLines > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph])) }
            renderedLines += 1
            var line = original, lineFont = font, lineParagraph = paragraph
            if !code {
                let header = index + 1 < lines.count && isTableDivider(lines[index + 1])
                if header { tableColumns = tableCells(original).count }
                let cells = tableCells(original)
                if tableColumns > 1, cells.count == tableColumns {
                    line = cells.joined(separator: "\t")
                    lineFont = header ? .systemFont(ofSize: font.pointSize, weight: .semibold) : .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    style.tabStops = (1..<tableColumns).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 112) }
                    style.defaultTabInterval = 112; style.paragraphSpacing = 4
                    if tableColumns == 2 { style.headIndent = 112 }
                    lineParagraph = style
                } else { tableColumns = 0 }
                if let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) { line.removeSubrange(range); lineFont = .systemFont(ofSize: font.pointSize + 1, weight: .semibold) }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            }
            let base: [NSAttributedString.Key: Any] = [.font: lineFont, .foregroundColor: color, .paragraphStyle: lineParagraph]
            if code { output.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), .foregroundColor: color, .backgroundColor: NSColor(white: 0.96, alpha: 1), .paragraphStyle: paragraph])); continue }
            guard let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { output.append(NSAttributedString(string: line, attributes: base)); continue }
            for run in parsed.runs {
                var attributes = base, f = lineFont
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                    if intent.contains(.code) { f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular); attributes[.backgroundColor] = NSColor(white: 0.95, alpha: 1) }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                if let link = run.link, let target = resolveLink?(link) ?? (["https", "http"].contains(link.scheme) ? link : nil) { attributes[.link] = target; attributes[.foregroundColor] = NSColor.linkColor }
                attributes[.font] = f
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        return output
    }

    private static func tableCells(_ line: String) -> [String] {
        guard line.contains("|") else { return [] }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|"), !value.hasSuffix("\\|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let cells = tableCells(line)
        return cells.count > 1 && cells.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
}
