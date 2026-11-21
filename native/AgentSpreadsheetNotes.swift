import Foundation

struct AgentSpreadsheetNote: Encodable, Sendable {
    let sheet: String, cell: String, author: String, text: String, editable: Bool
    let runs: [AgentSpreadsheetNoteRun]?
    let formatVersion: String?
}

struct AgentSpreadsheetNoteRun: Encodable, Sendable {
    let text: String
    let bold: Bool, italic: Bool, underline: Bool, doubleUnderline: Bool, strike: Bool
    let font: String?, size: Double?, rgb: String?, vertical: String?
}

struct AgentSpreadsheetNoteEdit: Decodable, Sendable {
    struct RichText: Decodable, Sendable {
        struct Run: Decodable, Sendable {
            let text: String, source: Int?
            let bold: Bool, italic: Bool, underline: Bool
        }
        let version: String?
        let runs: [Run]
    }
    let sheet: String, cell: String, original: String?, text: String
    let rich: RichText?
}

struct AgentSpreadsheetNoteCatalog: Encodable, Sendable {
    let notes: [AgentSpreadsheetNote]
    let creationUnavailable: [String]
    let author: String
}

enum AgentSpreadsheetNotes {
    static let limit = 5_000
    private static let xmlLimit = 2_000_000
    private static let sheetURI = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipURI = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationshipURI = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let contentTypeURI = "http://schemas.openxmlformats.org/package/2006/content-types"
    private static let contentTypesPart = "[Content_Types].xml"
    private static let vmlURI = "urn:schemas-microsoft-com:vml"
    private static let vmlOfficeURI = "urn:schemas-microsoft-com:office:office"
    private static let vmlExcelURI = "urn:schemas-microsoft-com:office:excel"
    static let noteAuthor = "小鲸"
    struct Relation {
        let id: String, kind: String, target: String
    }
    struct Sheet {
        let name: String, part: String, visible: Bool, supportsCreation: Bool
    }
    enum CommentAddition {
        case note(AgentSpreadsheetNoteEdit)
        case thread(cell: String, id: String, text: String)

        var cell: String {
            switch self {
            case .note(let edit): return edit.cell
            case .thread(let cell, _, _): return cell
            }
        }
    }
    fileprivate struct Note {
        let value: AgentSpreadsheetNote
        let content: XMLElement
        let runs: [XMLElement]
    }
    struct Package {
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
            let member = part == contentTypesPart ? "[[]Content_Types].xml" : part
            let data = try await AgentSpreadsheetNotes.command("/usr/bin/unzip", ["-p", archive.path, member], in: scratch, maximum: xmlLimit)
            let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
            guard document.dtd == nil, document.rootElement() != nil else { throw PetError("工作簿备注的 XML 无法读取") }
            return document
        }

        func relationshipPart(_ source: String) -> String {
            let pieces = source.split(separator: "/").map(String.init)
            return (Array(pieces.dropLast()) + ["_rels", (pieces.last ?? "") + ".rels"]).joined(separator: "/")
        }

        func relationshipDocument(_ source: String) async throws -> XMLDocument {
            let path = relationshipPart(source)
            let document: XMLDocument
            if entries.contains(path) { document = try await xml(path) }
            else { document = try XMLDocument(xmlString: "<Relationships xmlns=\"\(packageRelationshipURI)\"/>", options: []) }
            guard let root = document.rootElement(), root.localName == "Relationships", root.uri == packageRelationshipURI else {
                throw PetError("工作簿关联文件无效，草稿已保留")
            }
            return document
        }

        func relationships(_ source: String) async throws -> [Relation] {
            let path = relationshipPart(source)
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

        func workbookPart() async throws -> String {
            let root = try await relationships("").filter { $0.kind == "officeDocument" }
            guard root.count == 1, let workbook = root.first else { throw PetError("工作簿来源无法识别") }
            return try part(workbook.target, from: "")
        }

        func sheets() async throws -> [Sheet] {
            let path = try await workbookPart()
            let manifest = try await xml(path)
            let links = try await relationships(path)
            let target = Dictionary(uniqueKeysWithValues: links.filter { $0.kind == "worksheet" }.map { ($0.id, $0.target) })
            return try children(children(manifest.rootElement(), "sheets").first, "sheet").compactMap { node in
                let id = node.attribute(forLocalName: "id", uri: relationshipURI)?.stringValue ?? node.attribute(forName: "r:id")?.stringValue
                guard let name = attribute(node, "name"), let id, let address = target[id] else { return nil }
                return Sheet(name: name, part: try part(address, from: path), visible: (attribute(node, "state") ?? "visible") == "visible",
                             supportsCreation: manifest.rootElement()?.uri == sheetURI)
            }
        }

        func legacyComments(on sheet: Sheet, relations: [Relation]) async throws -> (part: String, document: XMLDocument)? {
            let notes = relations.filter { $0.kind == "comments" }
            guard !notes.isEmpty else { return nil }
            guard notes.count == 1, let relation = notes.first else { throw PetError("同一工作表包含多份备注文件") }
            let path = try part(relation.target, from: sheet.part)
            let document = try await xml(path)
            guard document.rootElement()?.localName == "comments" else { throw PetError("单元格备注格式无法识别") }
            return (path, document)
        }

        fileprivate func notes(on sheet: Sheet, relations: [Relation]) async throws -> (part: String, document: XMLDocument, entries: [Note])? {
            guard let legacy = try await legacyComments(on: sheet, relations: relations) else { return nil }
            let root = legacy.document.rootElement()
            let authorList = children(children(root, "authors").first, "author").map { $0.stringValue ?? "" }
            let threaded = hasThreadedComments(relations)
            let items = try children(children(root, "commentList").first, "comment").compactMap { item -> Note? in
                let authorID = attribute(item, "authorId").flatMap(Int.init)
                let author = authorID.flatMap { authorList.indices.contains($0) ? authorList[$0] : nil } ?? ""
                let placeholder = threadPlaceholderID(author) != nil
                if threaded && placeholder { return nil }
                guard let cell = attribute(item, "ref"), validCell(cell), let content = children(item, "text").first else {
                    throw PetError("单元格备注的位置或正文无法识别")
                }
                let direct = children(content, "t"), runs = children(content, "r")
                let fields = direct + runs.flatMap { children($0, "t") }
                let text = fields.map { $0.stringValue ?? "" }.joined()
                let knownElements = elements(content).count == direct.count + runs.count
                let plain = knownElements && direct.count == 1 && runs.isEmpty && elements(direct[0]).isEmpty
                let displayRuns = !runs.isEmpty ? direct.map { runStyle(nil, text: $0.stringValue ?? "") } + runs.map { run in
                    runStyle(children(run, "rPr").first, text: children(run, "t").first?.stringValue ?? "")
                } : nil
                let rich = knownElements && direct.count <= 1 && direct.allSatisfy { $0.uri == sheetURI && elements($0).isEmpty } &&
                    !runs.isEmpty && content.uri == sheetURI && runs.allSatisfy(validRun)
                let editable = !placeholder && (plain || rich) && validText(text)
                let version = rich ? AgentFiles.hash(Data(content.xmlString(options: [.nodePreserveAll]).utf8)) : nil
                return Note(value: .init(sheet: sheet.name, cell: cell, author: author, text: text, editable: editable,
                                         runs: displayRuns, formatVersion: version), content: content, runs: direct + runs)
            }
            guard items.count <= limit, Set(items.map { $0.value.cell }).count == items.count else {
                throw PetError("工作表包含重复备注或备注过多")
            }
            return (legacy.part, legacy.document, items)
        }
    }

    static func read(_ archive: URL) async throws -> [AgentSpreadsheetNote] {
        try await catalog(archive).notes
    }

    static func catalog(_ archive: URL) async throws -> AgentSpreadsheetNoteCatalog {
        let package = try await Package(archive)
        var result: [AgentSpreadsheetNote] = [], bytes = 0
        var unavailable: [String] = []
        for sheet in try await package.sheets() where sheet.visible {
            try Task.checkCancellation()
            let links = try await package.relationships(sheet.part)
            if !sheet.supportsCreation || hasThreadedComments(links) { unavailable.append(sheet.name) }
            guard let entry = try await package.notes(on: sheet, relations: links) else { continue }
            let notes = entry.entries.map(\.value)
            bytes += notes.reduce(0) { size, note in
                size + note.text.utf8.count + note.author.utf8.count + note.sheet.utf8.count +
                    (note.runs?.reduce(0) { $0 + $1.text.utf8.count + ($1.font?.utf8.count ?? 0) + 192 } ?? 0)
            }
            guard result.count + notes.count <= limit, bytes <= 4_000_000 else { throw PetError("工作簿备注超过可显示大小") }
            result.append(contentsOf: notes)
        }
        return .init(notes: result, creationUnavailable: unavailable, author: noteAuthor)
    }

    static func apply(_ edits: [AgentSpreadsheetNoteEdit], to archive: URL) async throws {
        guard !edits.isEmpty else { return }
        guard edits.count <= limit, edits.allSatisfy(validEdit),
              Set(edits.map { $0.sheet + "\0" + $0.cell }).count == edits.count else { throw PetError("备注修改格式无效") }
        let package = try await Package(archive)
        let sheets = try await package.sheets()
        guard Set(sheets.map(\.name)).count == sheets.count, Set(sheets.map(\.part)).count == sheets.count else {
            throw PetError("工作簿存在重名或重复的工作表，备注草稿已保留")
        }
        var documents: [String: XMLDocument] = [:], contentTypes: [String: String] = [:]
        var usedNames = Set(package.entries.map { $0.lowercased() })
        let grouped = Dictionary(grouping: edits, by: \.sheet)
        for name in grouped.keys.sorted() {
            guard let changes = grouped[name], let sheet = sheets.first(where: { $0.name == name && $0.visible }) else {
                throw PetError("备注的原工作表已变化，草稿已保留")
            }
            let links = try await package.relationships(sheet.part)
            let existing = try await package.notes(on: sheet, relations: links)
            let notes = Dictionary(uniqueKeysWithValues: (existing?.entries ?? []).map { ($0.value.cell, $0) })
            for edit in changes where edit.original != nil {
                guard let note = notes[edit.cell], note.value.editable, note.value.text == edit.original else {
                    throw PetError("单元格备注已变化，草稿已保留")
                }
                try writeBody(edit, to: note.content, original: note)
            }
            let additions = changes.filter { $0.original == nil }
            if additions.isEmpty, let existing {
                guard documents[existing.part] == nil else { throw PetError("多张工作表共用备注文件，原件已保留") }
                documents[existing.part] = existing.document
                continue
            }
            guard sheet.supportsCreation, !hasThreadedComments(links),
                  notes.count + additions.count <= limit, additions.allSatisfy({ notes[$0.cell] == nil }) else {
                throw PetError("该位置已有备注或工作表暂不支持新建，草稿已保留")
            }
            try await addLegacyComments(additions.map(CommentAddition.note), on: sheet, sheets: sheets, package: package, links: links,
                                        existing: existing.map { ($0.part, $0.document) }, documents: &documents,
                                        contentTypes: &contentTypes, usedNames: &usedNames)
        }
        try await appendContentTypes(contentTypes, to: &documents, package: package)
        try await write(documents, to: package)
    }

    static func appendContentTypes(_ contentTypes: [String: String], to documents: inout [String: XMLDocument], package: Package) async throws {
        guard !contentTypes.isEmpty else { return }
        let types = try await package.xml(contentTypesPart)
        guard let root = types.rootElement(), root.localName == "Types", root.uri == contentTypeURI else {
            throw PetError("工作簿内容类型无法读取")
        }
        for (path, contentType) in contentTypes.sorted(by: { $0.key < $1.key }) {
            let item = append("Override", to: root)
            set("PartName", "/" + path, on: item)
            set("ContentType", contentType, on: item)
        }
        documents[contentTypesPart] = types
    }

    static func write(_ documents: [String: XMLDocument], to package: Package) async throws {
        let folder = package.scratch.appendingPathComponent("spreadsheet-notes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try AgentFiles(workspace: folder.path, followParentLinks: false)
        for (path, document) in documents {
            try files.writeData(document.xmlData(options: [.nodePreserveAll]), to: files.literalURL(path), permissions: 0o600)
        }
        let paths = documents.keys.sorted()
        let replaced = paths.filter(package.entries.contains)
        // Update only the staged export. The user's original file is still
        // protected by the Office save checkpoint and source version check.
        if !replaced.isEmpty {
            _ = try await command("/usr/bin/zip", ["-q", "-d", "-nw", package.archive.path] + replaced, in: folder, scratch: package.scratch, writable: true)
        }
        _ = try await command("/usr/bin/zip", ["-q", "-X", "-nw", package.archive.path] + paths, in: folder, scratch: package.scratch, writable: true)
    }

    static func addLegacyComments(_ additions: [CommentAddition], on sheet: Sheet, sheets: [Sheet], package: Package,
                                  links: [Relation], existing: (part: String, document: XMLDocument)?,
                                  documents: inout [String: XMLDocument], contentTypes: inout [String: String],
                                  usedNames: inout Set<String>) async throws {
        let worksheet = try await package.xml(sheet.part)
        guard let root = worksheet.rootElement(), root.localName == "worksheet", root.uri == sheetURI else {
            throw PetError("原工作表无法读取，备注草稿已保留")
        }
        let relationshipPart = package.relationshipPart(sheet.part)
        let relationships = try await package.relationshipDocument(sheet.part)
        guard let relationshipRoot = relationships.rootElement() else { throw PetError("工作表关联无法读取") }

        let key = String(AgentFiles.hash(Data(sheet.part.utf8)).prefix(16))
        let commentsPath: String, comments: XMLDocument
        var changedLinks = false
        if let existing {
            try await requireUnshared(existing.part, kind: "comments", on: sheet, sheets: sheets, package: package)
            commentsPath = existing.part; comments = existing.document
        } else {
            commentsPath = unusedPart("xl/comments/notes-" + key, extension: "xml", used: &usedNames)
            comments = try XMLDocument(xmlString: "<comments xmlns=\"\(sheetURI)\"><authors/><commentList/></comments>", options: [])
            _ = addRelationship("comments", to: commentsPath, in: relationshipRoot)
            contentTypes[commentsPath] = "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"
            changedLinks = true
        }
        guard documents[commentsPath] == nil else { throw PetError("多张工作表共用备注文件，原件已保留") }
        try appendComments(additions, to: comments)
        documents[commentsPath] = comments

        let legacy = children(root, "legacyDrawing")
        guard legacy.count <= 1 else { throw PetError("工作表的备注绘图关联无效") }
        let drawingPath: String, drawing: XMLDocument
        if let prior = legacy.first {
            guard let id = prior.attribute(forLocalName: "id", uri: relationshipURI)?.stringValue ?? attribute(prior, "r:id"),
                  let link = links.first(where: { $0.id == id && $0.kind == "vmlDrawing" }) else {
                throw PetError("找不到原工作表的备注绘图，原件已保留")
            }
            drawingPath = try part(link.target, from: sheet.part)
            try await requireUnshared(drawingPath, kind: "vmlDrawing", on: sheet, sheets: sheets, package: package)
            drawing = try await package.xml(drawingPath)
        } else {
            drawingPath = unusedPart("xl/drawings/notes-" + key, extension: "vml", used: &usedNames)
            drawing = XMLDocument(rootElement: XMLElement(name: "xml"))
            let id = addRelationship("vmlDrawing", to: drawingPath, in: relationshipRoot)
            let element = XMLElement(name: qualified("legacyDrawing", in: root), uri: sheetURI)
            if let namespace = XMLNode.namespace(withName: "r", stringValue: relationshipURI) as? XMLNode {
                element.addNamespace(namespace)
            }
            set("r:id", id, on: element)
            // legacyDrawing follows drawings and precedes headers, objects,
            // tables and extensions in the worksheet schema.
            let following: Set<String> = ["legacyDrawingHF", "picture", "oleObjects", "controls", "webPublishItems", "tableParts", "extLst"]
            let index = root.children?.firstIndex { $0.uri == sheetURI && following.contains($0.localName ?? "") } ?? root.childCount
            root.insertChild(element, at: index)
            documents[sheet.part] = worksheet
            contentTypes[drawingPath] = "application/vnd.openxmlformats-officedocument.vmlDrawing"
            changedLinks = true
        }
        guard documents[drawingPath] == nil else { throw PetError("多张工作表共用备注绘图，原件已保留") }
        try appendShapes(additions.map(\.cell), to: drawing)
        documents[drawingPath] = drawing
        if changedLinks { documents[relationshipPart] = relationships }
    }

    static func requireUnshared(_ target: String, kind: String, on sheet: Sheet, sheets: [Sheet], package: Package) async throws {
        for other in sheets where other.part != sheet.part {
            let links = try await package.relationships(other.part)
            for link in links where link.kind == kind {
                if try part(link.target, from: other.part) == target {
                    throw PetError("多张工作表共用备注资源，原件已保留")
                }
            }
        }
    }

    static func addRelationship(_ type: String, to path: String, in root: XMLElement, namespace: String = relationshipURI) -> String {
        let ids = Set(children(root, "Relationship").compactMap { attribute($0, "Id") })
        let id = (1...(ids.count + 1)).lazy.map { "rId" + String($0) }.first { !ids.contains($0) }!
        let link = append("Relationship", to: root)
        set("Id", id, on: link); set("Type", namespace + "/" + type, on: link)
        set("Target", "/" + path, on: link)
        return id
    }

    static func unusedPart(_ prefix: String, extension suffix: String, used: inout Set<String>) -> String {
        var name = prefix + "." + suffix, index = 0
        while !used.insert(name.lowercased()).inserted {
            index += 1
            name = prefix + "-" + String(index) + "." + suffix
        }
        return name
    }

    private static func appendComments(_ additions: [CommentAddition], to document: XMLDocument) throws {
        guard let root = document.rootElement(), root.uri == sheetURI,
              let authors = children(root, "authors").first, let list = children(root, "commentList").first else {
            throw PetError("备注作者或列表无法读取，原件已保留")
        }
        let current = children(list, "comment")
        var occupied = Set(current.compactMap { attribute($0, "ref") })
        guard occupied.count == current.count, current.count + additions.count <= limit else {
            throw PetError("原工作簿的备注位置无法读取，草稿已保留")
        }
        var names = children(authors, "author").map { $0.stringValue ?? "" }
        for item in additions {
            guard occupied.insert(item.cell).inserted else { throw PetError("该单元格已有备注或评论，草稿已保留") }
            let name: String
            switch item {
            case .note: name = noteAuthor
            case .thread(_, let id, _): name = "tc=" + id
            }
            let authorID = names.firstIndex(of: name) ?? names.count
            if authorID == names.count { append("author", to: authors).stringValue = name; names.append(name) }
            let note = append("comment", to: list)
            set("ref", item.cell, on: note); set("authorId", String(authorID), on: note)
            let content = append("text", to: note)
            switch item {
            case .note(let edit): try writeBody(edit, to: content)
            case .thread(_, let id, let text):
                set("guid", id, on: note); set("shapeId", "0", on: note)
                writeText(text, to: append("t", to: content))
            }
        }
    }

    private static func validEdit(_ edit: AgentSpreadsheetNoteEdit) -> Bool {
        guard validCell(edit.cell), validText(edit.text), edit.original.map(validText) != false else { return false }
        guard let rich = edit.rich else { return true }
        return rich.runs.count <= 32_767 && rich.runs.map(\.text).joined() == edit.text &&
            rich.runs.allSatisfy { !$0.text.isEmpty && validText($0.text) && ($0.source ?? 0) >= 0 }
    }

    private static func validRun(_ run: XMLElement) -> Bool {
        let text = children(run, "t"), preferences = children(run, "rPr")
        return run.uri == sheetURI && text.count == 1 && text[0].uri == sheetURI && elements(text[0]).isEmpty &&
            preferences.count <= 1 && preferences.allSatisfy { $0.uri == sheetURI } &&
            elements(run).count == text.count + preferences.count
    }

    private static func runStyle(_ properties: XMLElement?, text: String) -> AgentSpreadsheetNoteRun {
        func member(_ key: String) -> XMLElement? { children(properties, key).first }
        func value(_ key: String) -> String? { member(key).flatMap { attribute($0, "val") } }
        func enabled(_ key: String) -> Bool { member(key) != nil && !["0", "false", "off", "none"].contains(value(key) ?? "") }
        let rgb = member("color").flatMap { attribute($0, "rgb") }
        let color = rgb.flatMap { $0.range(of: "^[0-9a-fA-F]{8}$", options: .regularExpression) != nil ? String($0.suffix(6)) : nil }
        return .init(text: text, bold: enabled("b"), italic: enabled("i"), underline: enabled("u"),
                     doubleUnderline: ["double", "doubleAccounting"].contains(value("u") ?? ""), strike: enabled("strike"),
                     font: value("rFont"), size: value("sz").flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                     rgb: color, vertical: value("vertAlign"))
    }

    private static func writeBody(_ edit: AgentSpreadsheetNoteEdit, to content: XMLElement, original: Note? = nil) throws {
        let format = original?.value.formatVersion
        guard format == edit.rich?.version else { throw PetError("单元格备注格式已变化，草稿已保留") }
        guard let rich = edit.rich, !rich.runs.isEmpty else {
            if let existing = children(content, "t").first {
                writeText(edit.text, to: existing)
            } else {
                content.setChildren(nil)
                writeText(edit.text, to: append("t", to: content))
            }
            return
        }
        let templates = format == nil ? [] : original?.runs ?? []
        let rendered = try rich.runs.map { patch -> XMLElement in
            let run: XMLElement, template: XMLElement?
            if let index = patch.source {
                guard templates.indices.contains(index), let clone = templates[index].copy() as? XMLElement else {
                    throw PetError("无法读回原备注格式，草稿已保留")
                }
                template = clone
            } else {
                template = nil
            }
            if let template, template.localName == "r" {
                run = template
            } else {
                run = XMLElement(name: qualified("r", in: content), uri: content.uri)
                if let template { run.addChild(template) }
            }
            let oldProperties = children(run, "rPr").first
            let style = runStyle(oldProperties, text: "")
            let changes = [("b", style.bold, patch.bold), ("i", style.italic, patch.italic), ("u", style.underline, patch.underline)]
                .filter { $0.1 != $0.2 }
            if !changes.isEmpty {
                let properties = oldProperties ?? XMLElement(name: qualified("rPr", in: run), uri: run.uri)
                if oldProperties == nil { run.insertChild(properties, at: 0) }
                for (name, _, enabled) in changes {
                    for child in children(properties, name) { child.detach() }
                    if enabled { insertRunProperty(name, into: properties) }
                }
            }
            let body = children(run, "t").first ?? append("t", to: run)
            if body.stringValue != patch.text { writeText(patch.text, to: body) }
            return run
        }
        content.setChildren(rendered)
    }

    private static func insertRunProperty(_ name: String, into properties: XMLElement) {
        // Excel expects this order even though the ISO schema uses a choice.
        let order = ["b", "i", "strike", "condense", "extend", "outline", "shadow", "u", "vertAlign", "sz", "color",
                     "rFont", "family", "charset", "scheme"]
        let rank = order.firstIndex(of: name)!
        let index = properties.children?.firstIndex {
            guard let child = $0.localName, let childRank = order.firstIndex(of: child) else { return false }
            return childRank > rank
        } ?? properties.childCount
        properties.insertChild(XMLElement(name: qualified(name, in: properties), uri: properties.uri), at: index)
    }

    private struct CellPosition: Hashable {
        let row: Int, column: Int
    }

    private static func appendShapes(_ cells: [String], to document: XMLDocument) throws {
        guard let root = document.rootElement(), root.localName == "xml" else { throw PetError("原备注绘图无法读取") }
        var occupied: Set<String> = []
        var anchors: Set<CellPosition> = []
        var pending = root.children ?? []
        while let item = pending.popLast() {
            guard let node = item as? XMLElement else { continue }
            pending.append(contentsOf: node.children ?? [])
            if node.uri == vmlURI {
                let shapeID = attribute(node, "id")
                let officeID = node.attribute(forLocalName: "spid", uri: vmlOfficeURI)?.stringValue
                for id in Set([shapeID, officeID].compactMap { $0 }) where id.hasPrefix("_x0000_s") {
                    guard occupied.insert(id).inserted else { throw PetError("原备注绘图含重复图形编号") }
                }
            }
            guard node.uri == vmlExcelURI, node.localName == "ClientData", attribute(node, "ObjectType") == "Note" else { continue }
            guard let row = children(node, "Row").first?.stringValue.flatMap(Int.init),
                  let column = children(node, "Column").first?.stringValue.flatMap(Int.init),
                  anchors.insert(CellPosition(row: row, column: column)).inserted else {
                throw PetError("原备注绘图含重复或无效位置")
            }
        }
        var positions: [CellPosition] = []
        for cell in cells {
            guard let position = cellPosition(cell) else { throw PetError("无效的备注位置") }
            if !anchors.contains(position) { positions.append(position) }
        }
        guard !positions.isEmpty else { return }
        if !children(root, "shapetype").contains(where: { $0.uri == vmlURI && attribute($0, "id") == "_x0000_t202" }) {
            let template = try XMLElement(xmlString: """
                <v:shapetype xmlns:v="\(vmlURI)" xmlns:o="\(vmlOfficeURI)" id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe">
                  <v:stroke joinstyle="miter"/><v:path gradientshapeok="t" o:connecttype="rect"/>
                </v:shapetype>
                """)
            let at = root.children?.firstIndex { $0.uri == vmlURI && ["shape", "group"].contains($0.localName ?? "") } ?? root.childCount
            root.insertChild(template, at: at)
        }
        var next = 1025, usedBlocks: [String] = []
        for position in positions {
            while occupied.contains("_x0000_s" + String(next)) { next += 1 }
            let block = String(next / 1024)
            if usedBlocks.last != block { usedBlocks.append(block) }
            root.addChild(try noteShape(id: next, at: position))
            next += 1
        }
        let layout = children(root, "shapelayout").first { $0.uri == vmlOfficeURI }
        if let layout, let map = children(layout, "idmap").first(where: { $0.uri == vmlOfficeURI }) {
            let existing = (attribute(map, "data") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let extras = usedBlocks.filter { !existing.contains($0) }
            if !extras.isEmpty { set("data", (existing + extras).joined(separator: ","), on: map) }
        } else if layout == nil {
            let map = try XMLElement(xmlString: """
                <o:shapelayout xmlns:o="\(vmlOfficeURI)" xmlns:v="\(vmlURI)" v:ext="edit">
                  <o:idmap v:ext="edit" data="\(usedBlocks.joined(separator: ","))"/>
                </o:shapelayout>
                """)
            root.insertChild(map, at: 0)
        } else {
            throw PetError("原备注绘图缺少图形编号映射，原件已保留")
        }
    }

    private static func noteShape(id: Int, at position: CellPosition) throws -> XMLElement {
        let left = min(position.column + 1, 16_381), top = min(position.row, 1_048_571)
        return try XMLElement(xmlString: """
            <v:shape xmlns:v="\(vmlURI)" xmlns:o="\(vmlOfficeURI)" xmlns:x="\(vmlExcelURI)"
                     id="_x0000_s\(id)" type="#_x0000_t202" fillcolor="#FFFFE1"
                     style="position:absolute;width:108pt;height:59pt;z-index:1;visibility:hidden" o:insetmode="auto">
              <v:fill color2="#FFFFE1"/><v:shadow on="t" color="#000000" obscured="t"/>
              <v:path o:connecttype="none"/><v:textbox><div style="text-align:left"/></v:textbox>
              <x:ClientData ObjectType="Note">
                <x:MoveWithCells/><x:SizeWithCells/>
                <x:Anchor>\(left), 12, \(top), 6, \(left + 2), 32, \(top + 4), 6</x:Anchor>
                <x:AutoFill>False</x:AutoFill><x:Row>\(position.row)</x:Row><x:Column>\(position.column)</x:Column>
              </x:ClientData>
            </v:shape>
            """)
    }

    private static func qualified(_ name: String, in element: XMLElement) -> String {
        if let prefix = element.prefix, !prefix.isEmpty { return prefix + ":" + name }
        return name
    }
    static func append(_ name: String, to parent: XMLElement) -> XMLElement {
        let child = XMLElement(name: qualified(name, in: parent), uri: parent.uri)
        parent.addChild(child)
        return child
    }
    static func set(_ name: String, _ value: String, on node: XMLElement) {
        if let attribute = node.attribute(forName: name) { attribute.stringValue = value }
        else if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode { node.addAttribute(attribute) }
    }
    private static func writeText(_ text: String, to node: XMLElement) {
        node.stringValue = text
        set("xml:space", "preserve", on: node)
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
    static func part(_ target: String, from source: String) throws -> String {
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
    static func children(_ node: XMLElement?, _ name: String) -> [XMLElement] {
        elements(node).filter { $0.localName == name }
    }
    private static func elements(_ node: XMLElement?) -> [XMLElement] {
        (node?.children ?? []).compactMap { $0 as? XMLElement }
    }
    static func attribute(_ node: XMLElement, _ name: String) -> String? { node.attribute(forName: name)?.stringValue }
    static func validCell(_ value: String) -> Bool { cellPosition(value) != nil }
    private static func cellPosition(_ value: String) -> CellPosition? {
        guard value.range(of: "^[A-Z]{1,3}[1-9][0-9]{0,6}$", options: .regularExpression) != nil,
              let firstNumber = value.firstIndex(where: \.isNumber), let row = Int(value[firstNumber...]), row <= 1_048_576 else { return nil }
        let column = value[..<firstNumber].utf8.reduce(0) { $0 * 26 + Int($1) - 64 }
        guard column <= 16_384 else { return nil }
        return CellPosition(row: row - 1, column: column - 1)
    }
    static func validText(_ text: String) -> Bool {
        text.utf16.count <= 32_767 && text.unicodeScalars.allSatisfy { scalar in
            let n = scalar.value
            return n == 9 || n == 10 || n == 13 || (32...0xD7FF).contains(n) || (0xE000...0xFFFD).contains(n) || n >= 0x10000
        }
    }
}
