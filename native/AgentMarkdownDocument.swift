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
    private(set) var images: [String: NSImage]
    private var imageRetries: [ImageRetry]
    private let legacyImageText: [LegacyImageText]
    var canRetryImages: Bool { !imageRetries.isEmpty }

    private enum ImageIssue: String {
        case missing = "图片未找到"
        case unreadable = "图片无法读取"
        case unsupported = "图片不可预览"
        case remote = "远程图片未加载"
        case limit = "本页图片预览已达到上限"

        var retryable: Bool { self == .missing || self == .unreadable }

        @MainActor func placeholder() -> NSImage {
            let background = AgentWorkbenchTheme.subtle
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: AgentWorkbenchTheme.secondaryText]
            let image = NSImage(size: NSSize(width: 164, height: 30), flipped: false) { rect in
                background.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                (rawValue as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 7),
                                            withAttributes: attributes)
                return true
            }
            image.accessibilityDescription = rawValue
            return image
        }
    }
    private struct ImageRetry {
        let reference: URL, attachment: NSTextAttachment
        var issue: ImageIssue
    }
    private struct ImageFailure: Error {
        let issue: ImageIssue, previousMessage: String
        init(_ issue: ImageIssue, previousMessage: String? = nil) {
            self.issue = issue
            self.previousMessage = previousMessage ?? issue.rawValue
        }
    }
    private struct LegacyImageText {
        let current: NSRange, previous: String
    }
    private struct ImageLoader {
        var images: [String: NSImage] = [:]
        var cached: [String: NSImage] = [:]
        var attempts = 0, pixels = 0

        @MainActor mutating func read(_ reference: URL, document: URL, files: AgentFiles) -> Result<NSImage, ImageFailure> {
            let url: URL
            do { url = try target(reference, document: document, files: files) }
            catch { return .failure(ImageFailure(.unsupported, previousMessage: error.localizedDescription)) }
            guard url.isFileURL else { return .failure(ImageFailure(.remote, previousMessage: "仅预览工作区内的图片")) }
            guard AgentDocument.imageTypes.contains(url.pathExtension.lowercased()) else {
                return .failure(ImageFailure(.unsupported, previousMessage: "仅预览工作区内的图片"))
            }
            if let picture = images[url.path] { return .success(picture) }
            guard attempts < 32, images.count < 32 else { return .failure(ImageFailure(.limit)) }
            attempts += 1
            let picture: NSImage
            if let previous = cached[url.path] { picture = previous }
            else {
                let data: Data
                do { data = try files.readData(url, maximum: 20_000_000) }
                catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
                    return .failure(ImageFailure(.missing, previousMessage: error.localizedDescription))
                }
                catch { return .failure(ImageFailure(.unreadable, previousMessage: error.localizedDescription)) }
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary) else { return .failure(ImageFailure(.unreadable)) }
                picture = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            let count = Int(picture.size.width * picture.size.height)
            guard pixels + count <= 16_000_000 else { return .failure(ImageFailure(.limit)) }
            pixels += count
            images[url.path] = picture
            return .success(picture)
        }
    }

    mutating func retryImages(document: URL, files: AgentFiles) -> Bool {
        var loader = ImageLoader(images: images, pixels: images.values.reduce(0) { $0 + Int($1.size.width * $1.size.height) })
        var changed = false
        imageRetries = imageRetries.compactMap { entry in
            switch loader.read(entry.reference, document: document, files: files) {
            case .success(let picture):
                entry.attachment.image = picture; changed = true
                return nil
            case .failure(let failure):
                let issue = failure.issue
                if issue != entry.issue { entry.attachment.image = issue.placeholder(); changed = true }
                return issue.retryable ? ImageRetry(reference: entry.reference, attachment: entry.attachment, issue: issue) : nil
            }
        }
        images = loader.images
        return changed
    }

    func migrateImageViewport(_ saved: AgentTextViewport, to text: NSTextView) throws -> AgentTextViewport? {
        guard !legacyImageText.isEmpty else { return nil }
        let current = body.string as NSString
        let previous = NSMutableString(capacity: current.length)
        var cursor = 0
        for entry in legacyImageText {
            previous.append(current.substring(with: NSRange(location: cursor, length: entry.current.location - cursor)))
            previous.append(entry.previous)
            cursor = NSMaxRange(entry.current)
        }
        previous.append(current.substring(from: cursor))
        // Only relocate selections from an exact match for the earlier rendering.
        guard previous.length == saved.count, AgentFiles.hash(Data((previous as String).utf8)) == saved.hash else { return nil }
        func location(_ old: Int) -> Int {
            var delta = 0
            for entry in legacyImageText {
                let start = entry.current.location + delta, length = entry.previous.utf16.count
                if old < start { break }
                if old < start + length { return entry.current.location }
                delta += length - entry.current.length
            }
            return old - delta
        }
        var viewport = try AgentTextViewport(text)
        viewport.anchor = location(saved.anchor)
        viewport.offset = saved.offset
        viewport.x = saved.x; viewport.y = saved.y; viewport.focused = saved.focused
        viewport.selections = saved.selections.map {
            let start = location($0.location), end = location($0.location + $0.length)
            return .init(location: start, length: end - start)
        }
        return viewport
    }

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
        var loader = ImageLoader(cached: cachedImages), imageRetries: [ImageRetry] = [], legacyImageText: [LegacyImageText] = []
        func resolveLink(_ link: URL) -> URL? { try? target(link, document: document, files: files) }
        func inline(_ text: String, font: NSFont = font, style: NSParagraphStyle = paragraph) -> NSAttributedString {
            NativeMarkdown.inline(text, font: font, color: .labelColor, paragraph: style, resolveLink: resolveLink)
        }
        func append(_ value: NSAttributedString) {
            output.append(value)
            output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        func heading(_ title: String, level: Int) {
            let rendered = inline(title, font: .systemFont(ofSize: CGFloat(25 - min(5, level) * 2), weight: .semibold))
            let headingTitle = AgentFileIcons.plainText(rendered), base = anchor(headingTitle)
            var name = base, count = 0
            while anchors.contains(name) { count += 1; name = base + "-\(count)" }; anchors.insert(name)
            headings.append(Heading(title: headingTitle, anchor: name, level: level, range: NSRange(location: output.length, length: rendered.length)))
            append(rendered)
        }
        while index < lines.count {
            let firstLine = index, displayStart = output.length
            var tableRegion = false
            let original = lines[index], trimmed = original.trimmingCharacters(in: .whitespaces)
            if let fenced = AgentMarkdownEditing.fencedCode(in: sourceLines, at: index) {
                index = fenced.lastLine
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = 10; style.firstLineHeadIndent = 10; style.lineSpacing = 2; style.lineBreakMode = .byCharWrapping
                let code = fenced.text, mermaid = fenced.info.lowercased() == "mermaid"
                if mermaid, diagrams.count < 16, code.utf8.count <= 32_768 {
                    let attachment = NSTextAttachment(); attachment.image = AgentMarkdownDiagrams.statusImage("正在绘制 Mermaid 图表…"); attachment.bounds = NSRect(x: 0, y: 0, width: min(340, max(160, width - 36)), height: 44)
                    let range = NSRange(location: output.length, length: 1)
                    let value = NSMutableAttributedString(attachment: attachment)
                    value.addAttributes([Self.selectedSource: "```mermaid\n" + code + "\n```", .toolTip: "Mermaid 图表 · 双击放大"], range: NSRange(location: 0, length: 1))
                    diagrams.append(Diagram(source: code, range: range, attachment: attachment)); append(value)
                } else {
                    if mermaid { append(inline("图表超过本页 16 张或单张 32KB 的预览上限")) }
                    append(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .backgroundColor: AgentWorkbenchTheme.subtle, .paragraphStyle: style]))
                }
            } else if let match = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                heading(String(trimmed[match.upperBound...]).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression), level: trimmed.prefix(while: { $0 == "#" }).count)
            } else if index + 1 < lines.count, !trimmed.isEmpty, lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: "^(={3,}|-{3,})$", options: .regularExpression) != nil {
                heading(trimmed, level: lines[index + 1].contains("=") ? 1 : 2); index += 1
            } else if let table = AgentMarkdownEditing.table(in: sourceLines, at: index) {
                let tableStart = sourceLines[index].range.location
                NativeMarkdown.appendTable(table, to: output, font: .systemFont(ofSize: 13), color: .labelColor, paragraph: paragraph, resolveLink: resolveLink) { row, column, values, display in
                    let line = table.rows[row]
                    if values.indices.contains(column) {
                        let raw = values[column].range
                        regions.append(AgentMarkdownEditing.Region(source: NSRange(location: line.range.location + raw.location, length: raw.length), display: display, kind: .cell(table: tableStart, row: row, column: column)))
                    } else {
                        regions.append(AgentMarkdownEditing.missingCell(line, column: column, existing: values.count, display: display, table: tableStart, row: row))
                    }
                }
                index += table.rows.count; tableRegion = true
            } else if let image = imageLink(trimmed) {
                let attachment = NSTextAttachment()
                let name = image.alt.isEmpty ? "图片" : image.alt
                var previous: String?
                switch loader.read(image.url, document: document, files: files) {
                case .success(let picture): attachment.image = picture
                case .failure(let failure):
                    let issue = failure.issue
                    previous = inline(name + " · " + failure.previousMessage).string + "\n"
                    if issue.retryable {
                        attachment.image = issue.placeholder()
                        imageRetries.append(ImageRetry(reference: image.url, attachment: attachment, issue: issue))
                    } else {
                        append(NSAttributedString(string: name + " · " + issue.rawValue,
                                                  attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: AgentWorkbenchTheme.secondaryText, .paragraphStyle: paragraph]))
                    }
                }
                if let picture = attachment.image {
                    let scale = min(1, max(160, width - 36) / picture.size.width)
                    attachment.bounds = NSRect(x: 0, y: 0, width: picture.size.width * scale, height: picture.size.height * scale)
                    let value = NSMutableAttributedString(attachment: attachment)
                    value.addAttributes([.toolTip: image.alt, Self.selectedSource: original], range: NSRange(location: 0, length: value.length))
                    append(value)
                    if !image.alt.isEmpty { append(inline(image.alt, font: .systemFont(ofSize: 11))) }
                }
                let range = NSRange(location: displayStart, length: output.length - displayStart)
                if let previous, output.attributedSubstring(from: range).string != previous {
                    legacyImageText.append(LegacyImageText(current: range, previous: previous))
                }
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
        return Self(body: output, headings: headings, diagrams: diagrams, regions: regions, images: loader.images,
                    imageRetries: imageRetries, legacyImageText: legacyImageText)
    }
    static func anchor(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }.replacingOccurrences(of: "\\s", with: "-", options: .regularExpression)
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
