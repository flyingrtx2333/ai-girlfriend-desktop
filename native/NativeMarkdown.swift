import AppKit

@MainActor enum NativeMarkdown {
    static func render(_ source: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle, resolveLink: ((URL) -> URL?)? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString(), lines = AgentMarkdownEditing.lines(source)
        var index = 0, needsLineBreak = false
        func beginLine() {
            if needsLineBreak { output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph])) }
            needsLineBreak = true
        }
        while index < lines.count {
            if let code = AgentMarkdownEditing.fencedCode(in: lines, at: index) {
                if !code.lines.isEmpty {
                    beginLine()
                    let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    style.lineBreakMode = .byCharWrapping
                    output.append(NSAttributedString(string: code.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), .foregroundColor: color, .backgroundColor: AgentWorkbenchTheme.subtle, .paragraphStyle: style]))
                }
                index = code.lastLine + 1
            } else if let table = AgentMarkdownEditing.table(in: lines, at: index) {
                beginLine()
                appendTable(table, to: output, font: font, color: color, paragraph: paragraph, resolveLink: resolveLink)
                needsLineBreak = false
                index += table.rows.count + 1
            } else {
                beginLine()
                var line = lines[index].text, lineFont = font
                if let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                    line.removeSubrange(range)
                    lineFont = NSFontManager.shared.convert(NSFontManager.shared.convert(font, toSize: font.pointSize + 1), toHaveTrait: .boldFontMask)
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
                output.append(inline(line, font: lineFont, color: color, paragraph: paragraph, codeSize: font.pointSize - 1, resolveLink: resolveLink))
                index += 1
            }
        }
        return output
    }

    static func appendTable(_ parsed: AgentMarkdownEditing.Table, to output: NSMutableAttributedString, font: NSFont, color: NSColor, paragraph: NSParagraphStyle, resolveLink: ((URL) -> URL?)? = nil, recordCell: ((Int, Int, [AgentMarkdownEditing.Cell], NSRange) -> Void)? = nil) {
        let table = NSTextTable()
        table.numberOfColumns = parsed.columns
        table.collapsesBorders = true
        let headingFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for (row, line) in parsed.rows.enumerated() {
            let values = AgentMarkdownEditing.cells(line.text), cellFont = row == 0 ? headingFont : font
            for column in parsed.alignment.indices {
                let start = output.length
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setValue(100 / CGFloat(parsed.columns), type: .percentageValueType, for: .width)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.backgroundColor = row == 0 ? AgentWorkbenchTheme.subtle : .textBackgroundColor
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.textBlocks = [block]
                style.alignment = parsed.alignment[column]
                style.lineBreakMode = .byCharWrapping
                style.lineSpacing = min(style.lineSpacing, 3)
                style.paragraphSpacing = 0
                let value = values.indices.contains(column) ? values[column].text : ""
                output.append(inline(value, font: cellFont, color: color, paragraph: style, tableLineBreaks: true, resolveLink: resolveLink))
                output.append(NSAttributedString(string: "\n", attributes: [.font: cellFont, .paragraphStyle: style]))
                recordCell?(row, column, values, NSRange(location: start, length: output.length - start))
            }
        }
    }

    static func inline(_ source: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle, codeSize: CGFloat? = nil, tableLineBreaks: Bool = false, resolveLink: ((URL) -> URL?)? = nil) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return NSAttributedString(string: source, attributes: base) }
        let output = NSMutableAttributedString(); var previousTarget: URL?
        for run in parsed.runs {
            var attributes = base, f = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { f = .monospacedSystemFont(ofSize: codeSize ?? (font.pointSize - 1), weight: .regular); attributes[.backgroundColor] = AgentWorkbenchTheme.subtle }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            let target = run.link.flatMap { link in resolveLink?(link) ?? (["https", "http"].contains(link.scheme) ? link : nil) }
            if let target {
                attributes[.link] = target; attributes[.foregroundColor] = NSColor.linkColor
                if target.isFileURL, previousTarget != target {
                    let icon = NSMutableAttributedString(attributedString: AgentFileIcons.attachment(filename: target.lastPathComponent, font: font))
                    icon.addAttributes([.link: target, .font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: icon.length)); output.append(icon)
                }
            }
            previousTarget = target
            attributes[.font] = f
            var text = String(parsed[run.range].characters)
            if tableLineBreaks, run.inlinePresentationIntent?.contains(.code) != true, text.contains("<") {
                text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\u{2028}", options: [.regularExpression, .caseInsensitive])
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }
}
