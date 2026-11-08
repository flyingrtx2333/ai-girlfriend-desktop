import Foundation
import CoreFoundation
import AppKit
import UniformTypeIdentifiers

enum AgentTextEncoding: String, CaseIterable {
    case utf8 = "utf-8", utf16LE = "utf-16le", utf16BE = "utf-16be", utf32LE = "utf-32le", utf32BE = "utf-32be"
    case gb18030 = "gb18030", big5 = "big5", shiftJIS = "shift-jis", windows1252 = "windows-1252", latin1 = "iso-8859-1"
    var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .utf32LE: return "UTF-32 LE"
        case .utf32BE: return "UTF-32 BE"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift JIS"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO-8859-1"
        }
    }
    var foundation: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        case .gb18030, .big5, .shiftJIS:
            let value = self == .gb18030 ? CFStringEncodings.GB_18030_2000 : self == .big5 ? .big5 : .shiftJIS
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
    }
    var marker: Data {
        switch self {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LE: return Data([0xFF, 0xFE])
        case .utf16BE: return Data([0xFE, 0xFF])
        case .utf32LE: return Data([0xFF, 0xFE, 0, 0])
        case .utf32BE: return Data([0, 0, 0xFE, 0xFF])
        default: return Data()
        }
    }
    static func markedEncoding(_ data: Data) -> Self? { [Self.utf32LE, .utf32BE, .utf8, .utf16LE, .utf16BE].first { data.starts(with: $0.marker) } }
    static func argument(_ value: String?) throws -> Self? {
        guard let value else { return nil }; guard let encoding = Self(rawValue: value) else { throw PetError("不支持的文本编码：" + value) }; return encoding
    }
    // A leading sentinel keeps Foundation from consuming an actual U+FEFF in
    // the body. Remove one Unicode scalar, rather than a grapheme cluster.
    func decodeBody(_ data: Data) throws -> String {
        let sentinel = "A".data(using: foundation)!
        guard let decoded = String(data: sentinel + data, encoding: foundation), decoded.unicodeScalars.first?.value == 65 else { throw PetError("无法按 " + title + " 解码，请选择编码重开") }
        let value = String(decoded.unicodeScalars.dropFirst())
        guard !value.contains("\0"), value.data(using: foundation, allowLossyConversion: false) == data else { throw PetError("无法按 " + title + " 无损读取，请选择编码重开") }
        return value
    }
}

struct AgentTextFormat: Equatable {
    var encoding: AgentTextEncoding = .utf8
    var bom = false
    var title: String { encoding.title + (bom ? " BOM" : "") }
    func encode(_ text: String) throws -> Data {
        guard !text.contains("\0"), !bom || !encoding.marker.isEmpty,
              let body = text.data(using: encoding.foundation, allowLossyConversion: false),
              let decoded = try? encoding.decodeBody(body), Data(decoded.utf8) == Data(text.utf8) else { throw PetError("无法用 " + title + " 保存，草稿已保留") }
        return (bom ? encoding.marker : Data()) + body
    }
}

@MainActor extension AgentTextEncoding {
    static func canReopen(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        return AgentDocument.textTypes.contains(ext) || ["", "markdown", "ini", "cfg", "conf", "properties", "strings", "plist", "lock"].contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }
    static func prepareMenu(_ menu: NSPopUpButton) {
        menu.addItem(withTitle: "自动检测"); menu.addItems(withTitles: allCases.map(\.title)); menu.controlSize = .small; menu.setAccessibilityLabel("编码重开")
        menu.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
    }
    static func selection(_ menu: NSPopUpButton) -> Self? { let index = menu.indexOfSelectedItem - 1; return allCases.indices.contains(index) ? allCases[index] : nil }
    static func updateMenu(_ menu: NSPopUpButton, requested: Self?, format: AgentTextFormat?) {
        menu.item(at: 0)?.title = format.map { "自动 · " + $0.title } ?? "自动检测"
        for (index, encoding) in allCases.enumerated() { menu.item(at: index + 1)?.title = encoding.title + (requested == encoding && format?.bom == true ? " BOM" : "") }
        menu.selectItem(at: requested.flatMap { allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
    }
}

struct AgentTextFile {
    let text: String, format: AgentTextFormat
    static func decode(_ data: Data, encoding requested: AgentTextEncoding? = nil) throws -> Self {
        guard data.count <= 4_000_000 else { throw PetError("文本超过 4MB，无法完整打开") }
        let marked = AgentTextEncoding.markedEncoding(data)
        if let requested, let marked, requested != marked { throw PetError("文件标记为 " + marked.title + "，请选择对应编码重开") }
        let encoding = requested ?? marked ?? .utf8, bom = marked != nil
        let body = bom ? Data(data.dropFirst(encoding.marker.count)) : data
        let text = try encoding.decodeBody(body)
        return Self(text: text, format: AgentTextFormat(encoding: encoding, bom: bom))
    }
    static func formatDescription(_ data: Data, encoding: AgentTextEncoding? = nil) -> String {
        guard let document = try? decode(data, encoding: encoding) else { return "编码不可读" }
        let rest = document.text.replacingOccurrences(of: "\r\n", with: "")
        let endings = [document.text.contains("\r\n") ? "CRLF" : nil, rest.contains("\n") ? "LF" : nil, rest.contains("\r") ? "CR" : nil].compactMap { $0 }
        return document.format.title + (endings.isEmpty ? "" : " · " + endings.joined(separator: "/"))
    }
}
