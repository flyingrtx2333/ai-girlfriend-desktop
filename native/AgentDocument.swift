import Foundation
import PDFKit
import ImageIO
import Vision
import AppKit

struct AgentDocumentPart: Codable, Sendable { var title: String; var text: String; var partial = false; var ocr: Bool? }
struct AgentDocumentContent: Codable, Sendable {
    var format: String; var parts: [AgentDocumentPart]; var totalParts: Int; var partial = false; var notes: [String] = []
}
struct AgentDocumentImage: Sendable { var jpeg: Data; var width: Int; var height: Int; var frames = 1 }

private final class AgentDocumentXML: NSObject, XMLParserDelegate {
    let start: (String, [String: String]) -> Void, characters: (String) -> Void, end: (String) -> Void
    private var depth = 0, elements = 0, bytes = 0
    init(start: @escaping (String, [String: String]) -> Void = { _, _ in }, characters: @escaping (String) -> Void = { _ in }, end: @escaping (String) -> Void = { _ in }) { self.start = start; self.characters = characters; self.end = end }
    func parse(_ data: Data) throws {
        let prefix = Array(data.prefix(4)), encoding: String.Encoding
        if prefix.starts(with: [0, 0, 0xfe, 0xff]) || prefix.starts(with: [0, 0, 0, 0x3c]) { encoding = .utf32BigEndian }
        else if prefix.starts(with: [0xff, 0xfe, 0, 0]) || prefix.starts(with: [0x3c, 0, 0, 0]) { encoding = .utf32LittleEndian }
        else if prefix.starts(with: [0xfe, 0xff]) || prefix.starts(with: [0, 0x3c]) { encoding = .utf16BigEndian }
        else if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0x3c, 0]) { encoding = .utf16LittleEndian }
        else { encoding = .utf8 }
        guard data.count <= 2_000_000, let decoded = String(data: data, encoding: encoding), !decoded.contains("\0"), !decoded.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw PetError("文档 XML 过大、编码无效或含不支持的声明") }
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { try Task.checkCancellation(); throw PetError("文档 XML 无法读取") }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; elements += 1
        if depth > 128 || elements > 100_000 || Task<Never, Never>.isCancelled { parser.abortParsing(); return }
        start(name.components(separatedBy: ":").last ?? name, attributes)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        bytes += string.utf8.count; if bytes > 2_000_000 { parser.abortParsing(); return }; characters(string)
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { parser.abortParsing(); return }; self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { end(name.components(separatedBy: ":").last ?? name); depth -= 1 }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

enum AgentDocument {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif"]
    static let textTypes: Set<String> = ["txt", "md", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml", "html", "htm", "svg", "log", "swift", "py", "js", "jsx", "ts", "tsx", "css", "sql", "sh", "rs", "go", "java", "c", "h", "cpp"]
    static func image(_ url: URL, maximumDimension: Int = 1536) throws -> AgentDocumentImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: min(1536, max(128, maximumDimension)), kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let jpeg = NSBitmapImageRep(cgImage: thumbnail).representation(using: .jpeg, properties: [.compressionFactor: 0.82]), jpeg.count <= 2_000_000 else { throw PetError("图片无法读取或过大") }
        return AgentDocumentImage(jpeg: jpeg, width: thumbnail.width, height: thumbnail.height, frames: CGImageSourceGetCount(source))
    }
    static func ocr(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]); try Task.checkCancellation()
        let rows = (request.results ?? []).sorted { a, b in abs(a.boundingBox.midY - b.boundingBox.midY) < 0.01 ? a.boundingBox.minX < b.boundingBox.minX : a.boundingBox.midY > b.boundingBox.midY }
        return String(rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(100_000))
    }
    static func pdfPage(_ url: URL, number: Int, recognize: Bool, render: Bool = false, maximumDimension: Int = 1536) throws -> (AgentDocumentPart, AgentDocumentImage?) {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, number > 0, number <= pdf.pageCount, let page = pdf.page(at: number - 1) else { throw PetError("PDF 页码无效或文件已加密") }
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extracted = AgentDocumentPart(title: "第 \(number) 页", text: String(text.prefix(100_000)), partial: text.count > 100_000)
        if !text.isEmpty && !render { return (extracted, nil) }
        guard recognize || render else { return (extracted, nil) }
        let box = page.bounds(for: .mediaBox)
        guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite, box.width > 0, box.height > 0 else { throw PetError("PDF 页面尺寸无效") }
        let scale = min(2, CGFloat(min(1536, max(128, maximumDimension))) / max(box.width, box.height))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError("PDF 页面无法绘制") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); context.scaleBy(x: scale, y: scale); context.translateBy(x: -box.minX, y: -box.minY); page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage(), let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { throw PetError("PDF 页面无法读取") }
        let part = text.isEmpty && recognize ? AgentDocumentPart(title: "第 \(number) 页 · OCR", text: try ocr(image), ocr: true) : extracted
        return (part, AgentDocumentImage(jpeg: jpeg, width: width, height: height))
    }
    static func extract(_ url: URL, scratch: URL, maximumSize: Int = 20_000_000, allowTextPrefix: Bool = false) async throws -> AgentDocumentContent {
        let type = url.pathExtension.lowercased(), size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumSize else { throw PetError("文件超过大小上限") }
        if type == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw PetError("PDF 无法读取或已加密") }
            var parts: [AgentDocumentPart] = [], count = 0
            for i in 0..<min(pdf.pageCount, 200) {
                try Task.checkCancellation(); let text = pdf.page(at: i)?.string ?? ""
                if count + text.utf8.count > 1_000_000 { break }
                count += text.utf8.count; parts.append(AgentDocumentPart(title: "第 \(i + 1) 页", text: text))
            }
            return AgentDocumentContent(format: type, parts: parts, totalParts: pdf.pageCount, partial: parts.count < pdf.pageCount, notes: parts.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ? ["无文字页面可按页进行本机 OCR"] : [])
        }
        if imageTypes.contains(type) {
            let normalized = try image(url)
            guard let source = CGImageSourceCreateWithData(normalized.jpeg as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PetError("图片无法解码") }
            return AgentDocumentContent(format: "image", parts: [AgentDocumentPart(title: "图片文字 · OCR", text: try ocr(image), ocr: true)], totalParts: normalized.frames, partial: normalized.frames > 1, notes: ["OCR 只识别文字，不代表图片已完成视觉理解"] + (normalized.frames > 1 ? ["仅第一帧"] : []))
        }
        if ["docx", "xlsx", "pptx"].contains(type) { return try await office(url, scratch: scratch) }
        guard textTypes.contains(type), allowTextPrefix || size <= 2_000_000 else { throw PetError("暂不支持此格式，请使用 PDF、DOCX、XLSX、PPTX、图片或文本") }
        let files = try AgentFiles(workspace: url.deletingLastPathComponent().path)
        var (data, partial) = try files.readPrefix(url, maximum: 2_000_000)
        if partial {
            for _ in 0..<3 where String(data: data, encoding: .utf8) == nil { data.removeLast() }
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw PetError("文件不是 UTF-8 文本") }
        return AgentDocumentContent(format: type, parts: [AgentDocumentPart(title: url.lastPathComponent, text: String(text.prefix(500_000)))], totalParts: 1, partial: partial || text.count > 500_000, notes: type == "svg" ? ["SVG源码，未渲染或执行脚本"] : [])
    }
    private static func xml(_ entry: String, archive: URL, scratch: URL, optional: Bool = false) async throws -> Data? {
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains(where: { "*?[]\0\n\r".contains($0) }), !entry.split(separator: "/").contains("..") else { throw PetError("文档内部路径无效") }
        let command = (["/usr/bin/unzip", "-p", archive.path, entry]).map { AgentGit.quote($0) }.joined(separator: " ")
        let result = try await AgentCommand().run(command: command, workspace: archive.deletingLastPathComponent(), scratch: scratch, network: false, timeout: 5, readOnly: true, maximumOutput: 2_000_000)
        if optional && result.exitCode == 11 { return nil }
        guard !result.failed, result.truncated != true, let data = result.stdoutData else { throw PetError("文档内容无法读取或单段超过 2MB") }
        return data
    }
    private static func relationship(_ data: Data, base: String) throws -> [String: String] {
        var result: [String: String] = [:]
        try AgentDocumentXML(start: { name, attributes in
            if name == "Relationship", attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"], !target.contains("\0"), !target.contains("\\") {
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : base + "/" + target
                var parts: [String] = []
                for part in path.split(separator: "/") { if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." { parts.append(String(part)) } }
                result[id] = parts.joined(separator: "/")
            }
        }).parse(data); return result
    }
    private static func paragraphs(_ data: Data) throws -> String {
        var text = "", inside = false, cellDepth = 0
        try AgentDocumentXML(start: { name, _ in
            if name == "tc" { cellDepth += 1 }
            if name == "t" { inside = true }; if name == "tab" { text += "\t" }; if name == "br" { text += "\n" }
        }, characters: { if inside { text += $0 } }, end: { name in
            if name == "t" { inside = false }; if name == "p" { text += cellDepth > 0 ? " " : "\n" }
            if name == "tc" { if text.hasSuffix(" ") { text.removeLast() }; text += "\t"; cellDepth -= 1 }
            if name == "tr" { if text.hasSuffix("\t") { text.removeLast() }; text += "\n" }
        }).parse(data)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func office(_ url: URL, scratch: URL) async throws -> AgentDocumentContent {
        let type = url.pathExtension.lowercased()
        if type == "docx" {
            let text = try paragraphs(await xml("word/document.xml", archive: url, scratch: scratch)!)
            return AgentDocumentContent(format: type, parts: [AgentDocumentPart(title: "正文", text: String(text.prefix(500_000)))], totalParts: 1, partial: text.count > 500_000, notes: ["仅正文文字；页眉页脚、图片、批注和修订状态未解释"])
        }
        let workbook = type == "xlsx", root = workbook ? "xl" : "ppt"
        let main = try await xml(workbook ? "xl/workbook.xml" : "ppt/presentation.xml", archive: url, scratch: scratch)!
        let rels = try relationship(await xml(workbook ? "xl/_rels/workbook.xml.rels" : "ppt/_rels/presentation.xml.rels", archive: url, scratch: scratch)!, base: root)
        var entries: [(String, String)] = [], date1904 = false, declared = 0
        try AgentDocumentXML(start: { name, attributes in
            if workbook && name == "workbookPr" { date1904 = ["1", "true"].contains(attributes["date1904"] ?? "") }
            if name == (workbook ? "sheet" : "sldId") { declared += 1 }
            if name == (workbook ? "sheet" : "sldId"), let id = attributes["r:id"], let path = rels[id], path.hasPrefix(root + (workbook ? "/worksheets/" : "/slides/")), path.hasSuffix(".xml"), path.count < 300 {
                entries.append((attributes["name"] ?? "幻灯片 \(declared)", path))
            }
        }).parse(main)
        var shared: [String] = [], formats: [String] = []
        if workbook {
            if let data = try await xml("xl/sharedStrings.xml", archive: url, scratch: scratch, optional: true) {
                var text = "", inside = false, phonetic = false
                try AgentDocumentXML(start: { name, _ in if name == "si" { text = "" }; if name == "rPh" { phonetic = true }; if name == "t" { inside = !phonetic } }, characters: { if inside { text += $0 } }, end: { name in if name == "t" { inside = false }; if name == "rPh" { phonetic = false }; if name == "si" { shared.append(text) } }).parse(data)
            }
            if let data = try await xml("xl/styles.xml", archive: url, scratch: scratch, optional: true) {
                var custom: [String: String] = [:], inCells = false
                let builtins = ["0": "General", "1": "0", "2": "0.00", "9": "0%", "10": "0.00%", "14": "m/d/yy", "15": "d-mmm-yy", "16": "d-mmm", "17": "mmm-yy", "18": "h:mm AM/PM", "19": "h:mm:ss AM/PM", "20": "h:mm", "21": "h:mm:ss", "22": "m/d/yy h:mm", "45": "mm:ss", "46": "[h]:mm:ss", "49": "@"]
                try AgentDocumentXML(start: { name, attributes in
                    if name == "numFmt", let id = attributes["numFmtId"], let code = attributes["formatCode"] { custom[id] = code }
                    if name == "cellXfs" { inCells = true }
                    if name == "xf" && inCells { let id = attributes["numFmtId"] ?? "0"; formats.append(custom[id] ?? builtins[id] ?? "numFmtId=" + id) }
                }, end: { if $0 == "cellXfs" { inCells = false } }).parse(data)
            }
        }
        var parts: [AgentDocumentPart] = [], bytes = 0
        for (title, entry) in entries.prefix(50) {
            try Task.checkCancellation(); let data = try await xml(entry, archive: url, scratch: scratch)!
            let text = workbook ? try cells(data, shared: shared, formats: formats) : try paragraphs(data)
            if bytes + text.utf8.count > 1_000_000 { break }; bytes += text.utf8.count; parts.append(AgentDocumentPart(title: title, text: text))
        }
        guard !parts.isEmpty else { throw PetError("文档没有可读取的工作表或幻灯片") }
        return AgentDocumentContent(format: type, parts: parts, totalParts: declared, partial: parts.count < declared, notes: workbook ? ["单元格为存储值，保留格式与公式；缓存结果未重新计算", "Excel 日期系统：\(date1904 ? 1904 : 1900)"] : ["按演示文稿顺序提取文字，未解释图片和图表"])
    }
    private static func cells(_ data: Data, shared: [String], formats: [String]) throws -> String {
        var lines: [String] = [], coordinate = "", type = "", style = 0, value = "", formula = "", inline = "", field = "", phonetic = false
        try AgentDocumentXML(start: { name, attributes in
            if name == "c" { coordinate = attributes["r"] ?? "?"; type = attributes["t"] ?? "n"; style = Int(attributes["s"] ?? "0") ?? 0; value = ""; formula = ""; inline = "" }
            if name == "rPh" { phonetic = true }
            if ["v", "f", "t"].contains(name) { field = phonetic ? "" : name }
        }, characters: { text in
            if field == "v" { value += text }; if field == "f" { formula += text }; if field == "t" { inline += text }
        }, end: { name in
            if name == field { field = "" }
            if name == "rPh" { phonetic = false }
            if name == "c" {
                let text = type == "s" ? Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "[共享文本索引无效]" : type == "inlineStr" ? inline : type == "b" ? (value == "1" ? "true" : "false") : value
                let format = formats.indices.contains(style) && formats[style] != "General" ? " [格式：\(formats[style])]" : ""
                lines.append(coordinate + ": " + text + format + (formula.isEmpty ? "" : " [公式：=" + formula + (value.isEmpty ? "；无缓存结果" : "") + "]"))
            }
        }).parse(data)
        return lines.joined(separator: "\n")
    }
}
