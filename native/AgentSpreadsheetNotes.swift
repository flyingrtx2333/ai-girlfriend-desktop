import Foundation

struct AgentSpreadsheetNote: Encodable, Sendable {
    let sheet: String, cell: String, author: String, text: String, editable: Bool
}

struct AgentSpreadsheetNoteEdit: Decodable, Sendable {
    let sheet: String, cell: String, original: String, text: String
}

enum AgentSpreadsheetNotes {
    private static let limit = 5_000
    private static let xmlLimit = 2_000_000
    private static let relationshipURI = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private struct Relation {
        let id: String, kind: String, target: String
    }
    private struct Sheet {
        let name: String, part: String, visible: Bool
    }
    private struct Note {
        let value: AgentSpreadsheetNote
        let text: XMLElement?
    }
    private struct Package {
        let archive: URL, scratch: URL, entries: Set<String>

        init(_ archive: URL) async throws {
            self.archive = archive; scratch = archive.deletingLastPathComponent()
            let bytes = try await AgentSpreadsheetNotes.command("/usr/bin/unzip", ["-Z1", archive.path], in: scratch, maximum: xmlLimit)
            guard let listing = String(data: bytes, encoding: .utf8) else { throw PetError("工作簿文件清单无法读取") }
            let names = listing.split(separator: "\n").map(String.init)
            entries = Set(names)
            guard !names.isEmpty, entries.count == names.count else { throw PetError("工作簿内有重复的文件路径") }
        }

        func xml(_ part: String) async throws -> XMLDocument {
            guard entries.contains(part) else { throw PetError("工作簿备注关联的文件缺失") }
            let data = try await AgentSpreadsheetNotes.command("/usr/bin/unzip", ["-p", archive.path, part], in: scratch, maximum: xmlLimit)
            let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
            guard document.dtd == nil, document.rootElement() != nil else { throw PetError("工作簿备注的 XML 无法读取") }
            return document
        }

        func relationships(_ source: String) async throws -> [Relation] {
            let pieces = source.split(separator: "/").map(String.init)
            let path = (Array(pieces.dropLast()) + ["_rels", (pieces.last ?? "") + ".rels"]).joined(separator: "/")
            guard entries.contains(path) else { return [] }
            let document = try await xml(path)
            let relations = try children(document.rootElement(), "Relationship").compactMap { item -> Relation? in
                guard let type = attribute(item, "Type"), let target = attribute(item, "Target"), let id = attribute(item, "Id") else {
                    throw PetError("工作簿备注的关联记录不完整")
                }
                guard attribute(item, "TargetMode") != "External" else { return nil }
                return Relation(id: id, kind: type.split(separator: "/").last.map(String.init) ?? "", target: target)
            }
            guard Set(relations.map(\.id)).count == relations.count else { throw PetError("工作簿的关联标识重复") }
            return relations
        }

        func sheets() async throws -> [Sheet] {
            let root = try await relationships("").filter { $0.kind == "officeDocument" }
            guard root.count == 1, let workbook = root.first else { throw PetError("工作簿来源无法识别") }
            let path = try part(workbook.target, from: "")
            let manifest = try await xml(path)
            let links = try await relationships(path)
            let target = Dictionary(uniqueKeysWithValues: links.filter { $0.kind == "worksheet" }.map { ($0.id, $0.target) })
            return try children(children(manifest.rootElement(), "sheets").first, "sheet").compactMap { node in
                let id = node.attribute(forLocalName: "id", uri: relationshipURI)?.stringValue ?? node.attribute(forName: "r:id")?.stringValue
                guard let name = attribute(node, "name"), let id, let address = target[id] else { return nil }
                return Sheet(name: name, part: try part(address, from: path), visible: (attribute(node, "state") ?? "visible") == "visible")
            }
        }

        func notes(on sheet: Sheet) async throws -> (part: String, document: XMLDocument, entries: [Note])? {
            let relations = try await relationships(sheet.part)
            let notes = relations.filter { $0.kind == "comments" }
            guard !notes.isEmpty else { return nil }
            guard notes.count == 1, let relation = notes.first else { throw PetError("同一工作表包含多份备注文件") }
            let path = try part(relation.target, from: sheet.part)
            let document = try await xml(path)
            let root = document.rootElement()
            guard root?.localName == "comments" else { throw PetError("单元格备注格式无法识别") }
            let authorList = children(children(root, "authors").first, "author").map { $0.stringValue ?? "" }
            let editAllowed = !relations.contains { $0.kind == "threadedComment" || $0.kind == "threadedComments" }
            let items = try children(children(root, "commentList").first, "comment").map { item -> Note in
                guard let cell = attribute(item, "ref"), validCell(cell), let content = children(item, "text").first else {
                    throw PetError("单元格备注的位置或正文无法识别")
                }
                let authorID = attribute(item, "authorId").flatMap(Int.init)
                let author = authorID.flatMap { authorList.indices.contains($0) ? authorList[$0] : nil } ?? ""
                let fields = children(content, "t") + children(content, "r").flatMap { children($0, "t") }
                let plain = children(content, "t").count == 1 && children(content, "r").isEmpty && fields.count == 1
                let text = fields.map { $0.stringValue ?? "" }.joined()
                let editable = editAllowed && plain && validText(text)
                return Note(value: .init(sheet: sheet.name, cell: cell, author: author, text: text, editable: editable),
                            text: editable ? fields.first : nil)
            }
            guard items.count <= limit, Set(items.map { $0.value.cell }).count == items.count else {
                throw PetError("工作表包含重复备注或备注过多")
            }
            return (path, document, items)
        }
    }

    static func read(_ archive: URL) async throws -> [AgentSpreadsheetNote] {
        let package = try await Package(archive)
        var result: [AgentSpreadsheetNote] = [], bytes = 0
        for sheet in try await package.sheets() where sheet.visible {
            try Task.checkCancellation()
            guard let entry = try await package.notes(on: sheet) else { continue }
            let notes = entry.entries.map(\.value)
            bytes += notes.reduce(0) { $0 + $1.text.utf8.count + $1.author.utf8.count + $1.sheet.utf8.count }
            guard result.count + notes.count <= limit, bytes <= 4_000_000 else { throw PetError("工作簿备注超过可显示大小") }
            result.append(contentsOf: notes)
        }
        return result
    }

    static func apply(_ edits: [AgentSpreadsheetNoteEdit], to archive: URL) async throws {
        guard !edits.isEmpty else { return }
        guard edits.count <= limit, edits.allSatisfy({ validCell($0.cell) && validText($0.original) && validText($0.text) }),
              Set(edits.map { $0.sheet + "\0" + $0.cell }).count == edits.count else { throw PetError("备注修改格式无效") }
        let package = try await Package(archive)
        let sheets = try await package.sheets().filter(\.visible)
        guard Set(sheets.map(\.name)).count == sheets.count else { throw PetError("工作簿存在重名工作表，备注草稿已保留") }
        var replacements: [String: Data] = [:]
        for (name, changes) in Dictionary(grouping: edits, by: \.sheet) {
            guard let sheet = sheets.first(where: { $0.name == name }),
                  let input = try await package.notes(on: sheet), replacements[input.part] == nil else {
                throw PetError("备注的原工作表已变化，草稿已保留")
            }
            let notes = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.value.cell, $0) })
            for change in changes {
                guard let note = notes[change.cell], let node = note.text, note.value.text == change.original else {
                    throw PetError("单元格备注已变化，草稿已保留")
                }
                node.stringValue = change.text
                if let space = node.attribute(forName: "xml:space") { space.stringValue = "preserve" }
                else if let space = XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as? XMLNode { node.addAttribute(space) }
            }
            replacements[input.part] = input.document.xmlData(options: [.nodePreserveAll])
        }
        let folder = package.scratch.appendingPathComponent("spreadsheet-notes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try AgentFiles(workspace: folder.path, followParentLinks: false)
        for (path, data) in replacements {
            try files.writeData(data, to: files.literalURL(path), permissions: 0o600)
        }
        let paths = replacements.keys.sorted()
        // Update only the staged export. The user's original file is still
        // protected by the Office save checkpoint and source version check.
        _ = try await command("/usr/bin/zip", ["-q", "-d", archive.path] + paths, in: folder, scratch: package.scratch, writable: true)
        _ = try await command("/usr/bin/zip", ["-q", "-X", archive.path] + paths, in: folder, scratch: package.scratch, writable: true)
    }

    private static func command(_ tool: String, _ args: [String], in directory: URL, scratch: URL? = nil,
                                maximum: Int = 20_000, writable: Bool = false) async throws -> Data {
        let result = try await AgentCommand().run(command: tool, workspace: directory, scratch: scratch ?? directory,
                                                   network: false, timeout: 20, readOnly: !writable,
                                                   maximumOutput: maximum, arguments: args)
        guard !result.failed, result.truncated != true, let data = result.stdoutData else {
            throw PetError(writable ? "备注未写入导出文件，草稿已保留" : "工作簿备注文件无法读取")
        }
        return data
    }
    private static func part(_ target: String, from source: String) throws -> String {
        var segments = target.hasPrefix("/") ? [] : Array(source.split(separator: "/").dropLast()).map(String.init)
        for name in target.split(separator: "/").map(String.init) {
            if name == "." { continue }
            if name == ".." {
                guard !segments.isEmpty else { throw PetError("工作簿的备注路径无效") }
                segments.removeLast(); continue
            }
            guard !name.contains(where: { !$0.isASCII || !($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                  !name.hasPrefix("-") else { throw PetError("工作簿的备注路径不受支持") }
            segments.append(name)
        }
        let path = segments.joined(separator: "/")
        guard !path.isEmpty, path.count <= 1024 else { throw PetError("工作簿的备注路径无效") }
        return path
    }
    private static func children(_ node: XMLElement?, _ name: String) -> [XMLElement] {
        (node?.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }
    private static func attribute(_ node: XMLElement, _ name: String) -> String? { node.attribute(forName: name)?.stringValue }
    private static func validCell(_ value: String) -> Bool {
        guard value.range(of: "^[A-Z]{1,3}[1-9][0-9]{0,6}$", options: .regularExpression) != nil,
              let firstNumber = value.firstIndex(where: \.isNumber), let row = Int(value[firstNumber...]), row <= 1_048_576 else { return false }
        return value[..<firstNumber].utf8.reduce(0) { $0 * 26 + Int($1) - 64 } <= 16_384
    }
    private static func validText(_ text: String) -> Bool {
        text.utf16.count <= 32_767 && text.unicodeScalars.allSatisfy { scalar in
            let n = scalar.value
            return n == 9 || n == 10 || n == 13 || (32...0xD7FF).contains(n) || (0xE000...0xFFFD).contains(n) || n >= 0x10000
        }
    }
}
