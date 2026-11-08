import AppKit
import ImageIO

@MainActor struct AgentMarkdownDocument {
    struct Heading { let title: String; let anchor: String; let level: Int; let range: NSRange }
    struct Diagram { let source: String; let range: NSRange; let attachment: NSTextAttachment }
    static let selectedSource = NSAttributedString.Key("BlueFatFishMarkdownSelectedSource")
    let body: NSAttributedString
    let headings: [Heading]
    let diagrams: [Diagram]
    let regions: [AgentMarkdownEditing.Region]
    let images: [String: NSImage]

    static func fragment(_ url: URL) -> String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment }

    static func reveal(_ range: NSRange, in text: NSTextView) {
        guard let container = text.textContainer, let layout = text.layoutManager, let scroll = text.enclosingScrollView else { return }
        text.window?.contentView?.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)
        text.setFrameSize(NSSize(width: text.frame.width, height: height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + text.textContainerOrigin.y - 12)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func lineRange(_ fragment: String?, in text: String) -> NSRange? {
        guard let fragment, fragment.range(of: "^L[1-9][0-9]*(?:-L?[1-9][0-9]*)?$", options: .regularExpression) != nil else { return nil }
        let parts = fragment.split(separator: "-"), rows = text.components(separatedBy: "\n")
        guard let first = Int(parts[0].dropFirst()), let last = parts.count == 1 ? first : Int(parts[1].drop(while: { $0 == "L" })), first <= last, last <= rows.count else { return nil }
        let start = rows.prefix(first - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return NSRange(location: start, length: (rows[(first - 1)...(last - 1)].joined(separator: "\n") as NSString).length)
    }

    // Resolve against the document, then apply the same canonical workspace and
    // sensitive-file boundaries used by the file tools. No implicit remote reads.
    static func target(_ link: URL, document: URL, files: AgentFiles) throws -> URL {
        if ["https", "http"].contains(link.scheme?.lowercased()) { return link }
        guard link.scheme == nil || link.isFileURL, link.host == nil || link.host == "" || link.host == "localhost",
              let parts = URLComponents(url: link, resolvingAgainstBaseURL: false), parts.query == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding else { throw PetError("不支持此链接") }
        let candidate = path.isEmpty ? document : path.hasPrefix("/") ? URL(fileURLWithPath: path) : document.deletingLastPathComponent().appendingPathComponent(path)
        let safe = try files.resolve(candidate.path)
        guard !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("不能预览受保护的文件") }
        var result = URLComponents(url: safe, resolvingAgainstBaseURL: false)!
        result.fragment = parts.fragment
        return result.url!
    }

    static func render(_ source: String, document: URL, files: AgentFiles, width: CGFloat, cachedImages: [String: NSImage] = [:]) -> Self {
        let output = NSMutableAttributedString(), font = NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 9
        let sourceLines = AgentMarkdownEditing.lines(source), lines = sourceLines.map(\.text)
        var headings: [Heading] = [], anchors: Set<String> = [], index = 0
        var diagrams: [Diagram] = []
        var regions: [AgentMarkdownEditing.Region] = []
        var images: [String: NSImage] = [:], imageAttempts = 0, decodedPixels = 0
        func inline(_ text: String, font: NSFont = font, style: NSParagraphStyle = paragraph) -> NSAttributedString {
            NativeMarkdown.inline(text, font: font, color: .labelColor, paragraph: style, resolveLink: { try? target($0, document: document, files: files) })
        }
        func append(_ value: NSAttributedString) {
            output.append(value)
            output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        func heading(_ title: String, level: Int) {
            let rendered = inline(title, font: .systemFont(ofSize: CGFloat(25 - min(5, level) * 2), weight: .semibold))
            let base = anchor(rendered.string)
            var name = base, count = 0
            while anchors.contains(name) { count += 1; name = base + "-\(count)" }; anchors.insert(name)
            headings.append(Heading(title: rendered.string, anchor: name, level: level, range: NSRange(location: output.length, length: rendered.length)))
            append(rendered)
        }
        while index < lines.count {
            let firstLine = index, displayStart = output.length
            var tableRegion = false
            let original = lines[index], trimmed = original.trimmingCharacters(in: .whitespaces)
            if let fence = fence(trimmed) {
                var content: [String] = []; index += 1
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    if let closing = Self.fence(line), closing.marker == fence.marker, closing.count >= fence.count, closing.info.isEmpty { break }
                    content.append(lines[index]); index += 1
                }
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = 10; style.firstLineHeadIndent = 10; style.lineSpacing = 2
                let code = content.joined(separator: "\n")
                if fence.info.lowercased() == "mermaid", diagrams.count < 16, code.utf8.count <= 32_768 {
                    let attachment = NSTextAttachment(); attachment.image = AgentMarkdownDiagrams.statusImage("正在绘制 Mermaid 图表…"); attachment.bounds = NSRect(x: 0, y: 0, width: min(340, max(160, width - 36)), height: 44)
                    let range = NSRange(location: output.length, length: 1)
                    let value = NSMutableAttributedString(attachment: attachment)
                    value.addAttributes([Self.selectedSource: "```mermaid\n" + code + "\n```", .toolTip: "Mermaid 图表 · 双击放大"], range: NSRange(location: 0, length: 1))
                    diagrams.append(Diagram(source: code, range: range, attachment: attachment)); append(value)
                } else {
                    if fence.info.lowercased() == "mermaid" { append(inline("图表超过本页 16 张或单张 32KB 的预览上限")) }
                    append(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor(white: 0.95, alpha: 1), .paragraphStyle: style]))
                }
            } else if let match = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                heading(String(trimmed[match.upperBound...]).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression), level: trimmed.prefix(while: { $0 == "#" }).count)
            } else if index + 1 < lines.count, !trimmed.isEmpty, lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: "^(={3,}|-{3,})$", options: .regularExpression) != nil {
                heading(trimmed, level: lines[index + 1].contains("=") ? 1 : 2); index += 1
            } else if index + 1 < lines.count, let alignment = AgentMarkdownEditing.tableAlignment(lines[index + 1]), cells(original).count == alignment.count {
                let tableStart = sourceLines[index].range.location
                var rows = [(line: index, cells: AgentMarkdownEditing.cells(original))]; index += 2
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, lines[index].contains("|") { rows.append((line: index, cells: AgentMarkdownEditing.cells(lines[index]))); index += 1 }
                let table = NSTextTable(); table.numberOfColumns = alignment.count; table.collapsesBorders = true; table.layoutAlgorithm = .automaticLayoutAlgorithm
                for (row, entry) in rows.enumerated() {
                    for column in alignment.indices {
                        let cellStart = output.length, values = entry.cells
                        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        block.setValue(100 / CGFloat(alignment.count), type: .percentageValueType, for: .width)
                        block.setWidth(7, type: .absoluteValueType, for: .padding)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border); block.setBorderColor(.separatorColor)
                        block.backgroundColor = row == 0 ? NSColor(white: 0.95, alpha: 1) : .white
                        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle; style.textBlocks = [block]; style.alignment = alignment[column]; style.paragraphSpacing = 3
                        let value = (column < values.count ? values[column].text : "").replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
                        output.append(inline(value, font: row == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13), style: style))
                        output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
                        let display = NSRange(location: cellStart, length: output.length - cellStart), line = sourceLines[entry.line]
                        if column < values.count {
                            let raw = values[column].range
                            regions.append(AgentMarkdownEditing.Region(source: NSRange(location: line.range.location + raw.location, length: raw.length), display: display, kind: .cell(table: tableStart, row: row, column: column)))
                        } else { regions.append(AgentMarkdownEditing.missingCell(line, column: column, existing: values.count, display: display, table: tableStart, row: row)) }
                    }
                }
                index -= 1; tableRegion = true
            } else if let image = imageLink(trimmed) {
                do {
                    let url = try target(image.url, document: document, files: files)
                    guard url.isFileURL, AgentDocument.imageTypes.contains(url.pathExtension.lowercased()) else { throw PetError("仅预览工作区内的图片") }
                    let picture: NSImage
                    if let cached = images[url.path] { picture = cached }
                    else {
                        guard imageAttempts < 32 else { throw PetError("本页图片预览已达到上限") }; imageAttempts += 1
                        if let cached = cachedImages[url.path] { picture = cached }
                        else {
                            let data = try files.readData(try files.resolve(url.path), maximum: 20_000_000)
                            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary) else { throw PetError("图片无法读取") }
                            picture = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        }
                        let pixels = Int(picture.size.width * picture.size.height)
                        guard decodedPixels + pixels <= 16_000_000 else { throw PetError("本页图片预览已达到上限") }
                        decodedPixels += pixels; images[url.path] = picture
                    }
                    let attachment = NSTextAttachment(), available = max(160, width - 36), scale = min(1, available / picture.size.width)
                    attachment.image = picture
                    attachment.bounds = NSRect(x: 0, y: 0, width: picture.size.width * scale, height: picture.size.height * scale)
                    let value = NSMutableAttributedString(attachment: attachment); value.addAttributes([.toolTip: image.alt, Self.selectedSource: original], range: NSRange(location: 0, length: value.length)); append(value)
                    if !image.alt.isEmpty { append(inline(image.alt, font: .systemFont(ofSize: 11))) }
                } catch { append(inline((image.alt.isEmpty ? "图片" : image.alt) + " · " + error.localizedDescription)) }
            } else if trimmed.hasPrefix(">") {
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle; style.headIndent = 16; style.firstLineHeadIndent = 16
                append(inline(trimmed.replacingOccurrences(of: "^>\\s?", with: "", options: .regularExpression), style: style))
            } else if trimmed.range(of: "^([-*_])(?:\\s*\\1){2,}$", options: .regularExpression) != nil {
                append(NSAttributedString(string: "────────────", attributes: [.foregroundColor: NSColor.separatorColor, .paragraphStyle: paragraph]))
            } else {
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                var value = original
                if let range = original.range(of: "^\\s*(?:[-*+] |[0-9]+[.)] )", options: .regularExpression) {
                    let indent = CGFloat(original.prefix(while: { $0.isWhitespace }).count / 2) * 14
                    style.firstLineHeadIndent = indent; style.headIndent = indent + 18
                    value = String(original[range.upperBound...])
                    let marker = original[range].trimmingCharacters(in: .whitespaces)
                    value = (marker.first?.isNumber == true ? marker : "•") + " " + value
                    value = value.replacingOccurrences(of: "• [x] ", with: "☑ ").replacingOccurrences(of: "• [X] ", with: "☑ ").replacingOccurrences(of: "• [ ] ", with: "☐ ")
                }
                append(inline(value, style: style))
            }
            if !tableRegion {
                let last = sourceLines[min(index, sourceLines.count - 1)], first = sourceLines[firstLine]
                regions.append(AgentMarkdownEditing.Region(source: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), display: NSRange(location: displayStart, length: output.length - displayStart), kind: .block))
            }
            index += 1
        }
        return Self(body: output, headings: headings, diagrams: diagrams, regions: regions, images: images)
    }
    static func anchor(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }.replacingOccurrences(of: "\\s", with: "-", options: .regularExpression)
    }
    private static func fence(_ line: String) -> (marker: Character, count: Int, info: String)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let count = line.prefix(while: { $0 == marker }).count
        return count >= 3 ? (marker, count, String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)) : nil
    }
    static func cells(_ line: String) -> [String] {
        AgentMarkdownEditing.cells(line).map(\.text)
    }
    private static func imageLink(_ text: String) -> (alt: String, url: URL)? {
        if text.range(of: "^<img\\s+[^>]+/?>$", options: [.regularExpression, .caseInsensitive]) != nil,
           let attrs = try? NSRegularExpression(pattern: "(src|alt)\\s*=\\s*([\"'])(.*?)\\2", options: [.caseInsensitive]) {
            var values: [String: String] = [:]
            for match in attrs.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 3), in: text) {
                    values[String(text[key]).lowercased()] = String(text[value]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                }
            }
            if let src = values["src"], let url = URL(string: src) { return (values["alt"] ?? "", url) }
        }
        guard let regex = try? NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\s]+?)(?:\\s+\"[^\"]*\")?\\)$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let alt = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text), let url = URL(string: String(text[value])) else { return nil }
        return (String(text[alt]), url)
    }
}
