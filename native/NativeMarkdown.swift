import AppKit

@MainActor enum NativeMarkdown {
    static func render(_ source: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        let output = NSMutableAttributedString(); var code = false
        for (index, original) in source.components(separatedBy: "\n").enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph])) }
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { code.toggle(); continue }
            var line = original, lineFont = font
            if !code {
                if let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) { line.removeSubrange(range); lineFont = .systemFont(ofSize: font.pointSize + 1, weight: .semibold) }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            }
            let base: [NSAttributedString.Key: Any] = [.font: lineFont, .foregroundColor: color, .paragraphStyle: paragraph]
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
                if let link = run.link, ["https", "http"].contains(link.scheme) { attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor }
                attributes[.font] = f
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        return output
    }
}
