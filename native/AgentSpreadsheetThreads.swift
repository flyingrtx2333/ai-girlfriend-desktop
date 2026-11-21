import Foundation

struct AgentSpreadsheetThread: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let id: String, parent: String?, author: String, time: String?, text: String
    }
    let id: String, sheet: String, cell: String, version: String
    let resolved: Bool, editable: Bool
    let messages: [Message]
}

struct AgentSpreadsheetThreadCatalog: Encodable, Sendable {
    let threads: [AgentSpreadsheetThread]
    let incomplete: Bool
    let author: String
    let creation: [String: [String]]
}

struct AgentSpreadsheetThreadEdit: Decodable, Sendable {
    struct Reply: Decodable, Sendable {
        let id: String, time: String, text: String
    }
    let id: String, sheet: String, cell: String, version: String?
    let opening: Reply?
    let resolved: Bool
    let replies: [Reply]
}

extension AgentSpreadsheetNotes {
    private static let threadURI = "http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments"
    private static let threadRelationshipURI = "http://schemas.microsoft.com/office/2017/10/relationships"
    private static let localThreadAuthor = "{2FC87B65-B203-4D68-B084-A0A6F4B69611}"
    private static let escapedText = try! NSRegularExpression(pattern: "_x([0-9a-fA-F]{4})_")

    private struct People {
        let part: String, document: XMLDocument, root: XMLElement, names: [String: String]
    }
    private struct ThreadSheet {
        struct Entry {
            let value: AgentSpreadsheetThread, root: XMLElement
        }
        let part: String, kind: String, document: XMLDocument, root: XMLElement, entries: [Entry], ids: Set<String>
    }
    private struct ThreadMessageNode {
        let message: AgentSpreadsheetThread.Message, xml: XMLElement, knownAuthor: Bool
    }

    static func hasThreadedComments(_ relations: [Relation]) -> Bool {
        relations.contains { isThreadRelationship($0) }
    }

    static func threadPlaceholderID(_ author: String) -> String? {
        guard let prefix = author.range(of: "tc=", options: .caseInsensitive) else { return nil }
        return threadID(String(author[prefix.upperBound...].prefix(38)))
    }

    private static func threadID(_ value: String?) -> String? {
        guard let value else { return nil }
        let bare = value.hasPrefix("{") && value.hasSuffix("}") ? String(value.dropFirst().dropLast()) : value
        guard bare.utf8.count == 36, let id = UUID(uuidString: bare) else { return nil }
        return "{" + id.uuidString + "}"
    }

    private static func isThreadRelationship(_ relation: Relation) -> Bool {
        relation.kind == "threadedComment" || relation.kind == "threadedComments"
    }

    static func threadCatalog(_ archive: URL) async throws -> AgentSpreadsheetThreadCatalog {
        let package = try await Package(archive), workbook = try await package.workbookPart()
        let people = try await readPeople(package, workbook: workbook)
        var threads: [AgentSpreadsheetThread] = [], rootIDs: Set<String> = [], bytes = 0, messageCount = 0, incomplete = false
        var creation: [String: [String]] = [:], hasThreadsWithoutPeople = false
        for sheet in try await package.sheets() where sheet.visible || people == nil {
            try Task.checkCancellation()
            do {
                let links = try await package.relationships(sheet.part)
                let threaded = hasThreadedComments(links)
                if threaded && people == nil { hasThreadsWithoutPeople = true }
                guard sheet.visible else { continue }
                let legacy = try await package.legacyComments(on: sheet, relations: links)?.document
                let occupied = try legacyCommentCells(legacy)
                let entries = threaded
                    ? try await readThreadSheet(sheet, links: links, people: people?.names ?? [:], legacy: legacy, package: package).entries.map(\.value)
                    : []
                let ids = Set(entries.map(\.id))
                let count = entries.reduce(0) { $0 + $1.messages.count }
                let size = entries.reduce(0) { result, thread in
                    result + thread.sheet.utf8.count + thread.messages.reduce(0) { $0 + $1.author.utf8.count + $1.text.utf8.count + 160 }
                }
                guard ids.count == entries.count, rootIDs.isDisjoint(with: ids),
                      count + messageCount <= limit, bytes + size <= 4_000_000 else {
                    throw PetError("工作簿评论过多或编号重复")
                }
                threads.append(contentsOf: entries); rootIDs.formUnion(ids); bytes += size; messageCount += count
                if sheet.supportsCreation { creation[sheet.name] = occupied.sorted() }
            } catch is CancellationError { throw CancellationError() }
            catch { incomplete = true }
        }
        return .init(threads: threads, incomplete: incomplete, author: noteAuthor, creation: hasThreadsWithoutPeople ? [:] : creation)
    }

    static func applyThreads(_ edits: [AgentSpreadsheetThreadEdit], to archive: URL) async throws {
        guard !edits.isEmpty else { return }
        let invalid = PetError("评论修改无效，草稿已保留")
        guard edits.count <= limit, Set(edits.map(\.id)).count == edits.count, edits.allSatisfy({ edit in
            threadID(edit.id) == edit.id && validCell(edit.cell) &&
                (edit.opening.map { $0.id == edit.id && edit.version == nil } ?? (edit.version != nil))
        }) else { throw invalid }
        let messages = edits.flatMap { edit in (edit.opening.map { [$0] } ?? []) + edit.replies }
        guard messages.count <= limit, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ reply in
                  threadID(reply.id) == reply.id && reply.time.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$",
                                                                   options: .regularExpression) != nil &&
                  validText(reply.text) && !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { throw invalid }
        let package = try await Package(archive), workbook = try await package.workbookPart()
        let sheets = try await package.sheets()
        guard Set(sheets.map(\.name)).count == sheets.count, Set(sheets.map(\.part)).count == sheets.count else { throw invalid }
        var documents: [String: XMLDocument] = [:], contentTypes: [String: String] = [:]
        var usedNames = Set(package.entries.map { $0.lowercased() })
        let people: People
        if let existing = try await readPeople(package, workbook: workbook) { people = existing }
        else {
            guard edits.allSatisfy({ $0.opening != nil }) else { throw invalid }
            for sheet in sheets {
                if hasThreadedComments(try await package.relationships(sheet.part)) {
                    throw PetError("原工作簿缺少评论作者，草稿已保留")
                }
            }
            let path = unusedPart("xl/persons/person", extension: "xml", used: &usedNames)
            let document = try XMLDocument(xmlString: "<personList xmlns=\"\(threadURI)\"/>", options: [])
            let relations = try await package.relationshipDocument(workbook)
            guard let root = document.rootElement(), let relationshipRoot = relations.rootElement() else { throw invalid }
            _ = addRelationship("person", to: path, in: relationshipRoot, namespace: threadRelationshipURI)
            documents[package.relationshipPart(workbook)] = relations
            contentTypes[path] = "application/vnd.ms-excel.person+xml"
            people = .init(part: path, document: document, root: root, names: [:])
        }
        let grouped = Dictionary(grouping: edits, by: \.sheet)
        for name in grouped.keys.sorted() {
            guard let changes = grouped[name] else { continue }
            guard let sheet = sheets.first(where: { $0.name == name && $0.visible }) else {
                throw PetError("评论的工作表已变化，草稿已保留")
            }
            let links = try await package.relationships(sheet.part)
            let legacy = try await package.legacyComments(on: sheet, relations: links)
            let createPart = !hasThreadedComments(links)
            let source: ThreadSheet
            if createPart {
                guard changes.allSatisfy({ $0.opening != nil }) else { throw invalid }
                let key = String(AgentFiles.hash(Data(sheet.part.utf8)).prefix(16))
                let path = unusedPart("xl/threadedComments/threadedComment-" + key, extension: "xml", used: &usedNames)
                let document = try XMLDocument(xmlString: "<ThreadedComments xmlns=\"\(threadURI)\"/>", options: [])
                guard let root = document.rootElement() else { throw invalid }
                source = .init(part: path, kind: "threadedComment", document: document, root: root, entries: [], ids: [])
                contentTypes[path] = "application/vnd.ms-excel.threadedcomments+xml"
            } else {
                source = try await readThreadSheet(sheet, links: links, people: people.names, legacy: legacy?.document, package: package)
                try await requireUnshared(source.part, kind: source.kind, on: sheet, sheets: sheets, package: package)
            }
            guard documents[source.part] == nil else { throw invalid }
            let entries = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.value.id, $0) })
            var ids = source.ids
            var occupied = try legacyCommentCells(legacy?.document)
            occupied.formUnion(source.entries.map { $0.value.cell })
            var placeholders: [CommentAddition] = []
            for edit in changes {
                if let opening = edit.opening {
                    guard sheet.supportsCreation, occupied.insert(edit.cell).inserted,
                          ids.insert(edit.id).inserted, ids.count <= limit else {
                        throw PetError("该单元格已有备注或评论，或工作表暂不可新增，草稿已保留")
                    }
                    let element = addMessage(opening, parent: nil, cell: edit.cell, to: source.root)
                    if edit.resolved { set("done", "1", on: element) }
                    placeholders.append(.thread(cell: edit.cell, id: edit.id, text: encodeThreadText(opening.text)))
                } else {
                    guard let entry = entries[edit.id], entry.value.editable, entry.value.cell == edit.cell,
                          entry.value.version == edit.version else { throw PetError("原评论或单元格已变化，草稿已保留") }
                    if edit.resolved != entry.value.resolved { set("done", edit.resolved ? "1" : "0", on: entry.root) }
                }
                for reply in edit.replies {
                    guard ids.insert(reply.id).inserted, ids.count <= limit else { throw invalid }
                    _ = addMessage(reply, parent: edit.id, cell: edit.cell, to: source.root)
                }
            }
            if !placeholders.isEmpty {
                try await addLegacyComments(placeholders, on: sheet, sheets: sheets, package: package, links: links,
                                            existing: legacy, documents: &documents, contentTypes: &contentTypes, usedNames: &usedNames)
            }
            if createPart {
                let path = package.relationshipPart(sheet.part)
                let relations: XMLDocument
                if let staged = documents[path] { relations = staged }
                else { relations = try await package.relationshipDocument(sheet.part) }
                guard let root = relations.rootElement() else { throw invalid }
                _ = addRelationship("threadedComment", to: source.part, in: root, namespace: threadRelationshipURI)
                documents[path] = relations
            }
            documents[source.part] = source.document
        }
        if !messages.isEmpty {
            if let person = children(people.root, "person").first(where: { threadID(attribute($0, "id")) == localThreadAuthor }) {
                guard people.names[localThreadAuthor] == noteAuthor, attribute(person, "providerId") == "None",
                      attribute(person, "userId") == noteAuthor else { throw invalid }
            } else {
                let element = appendThreadItem("person", to: people.root)
                set("displayName", noteAuthor, on: element); set("id", localThreadAuthor, on: element)
                set("providerId", "None", on: element); set("userId", noteAuthor, on: element)
                documents[people.part] = people.document
            }
        }
        try await appendContentTypes(contentTypes, to: &documents, package: package)
        guard documents.values.allSatisfy({ $0.xmlData(options: [.nodePreserveAll]).count <= 2_000_000 }) else {
            throw PetError("评论文件过大，草稿已保留")
        }
        try await write(documents, to: package)
    }

    private static func readPeople(_ package: Package, workbook: String) async throws -> People? {
        let links = try await package.relationships(workbook).filter { $0.kind == "person" }
        if links.isEmpty { return nil }
        guard links.count == 1, let link = links.first else { throw PetError("工作簿的评论作者关联无法读取") }
        let path = try part(link.target, from: workbook)
        let document = try await package.xml(path)
        guard let root = document.rootElement(), root.localName == "personList", root.uri == threadURI else {
            throw PetError("工作簿的评论作者列表无法读取")
        }
        var people: [String: String] = [:]
        for person in children(root, "person") where person.uri == threadURI {
            guard let id = threadID(attribute(person, "id")), let name = attribute(person, "displayName"),
                  people[id] == nil else { throw PetError("工作簿的评论作者编号无效") }
            people[id] = decodeThreadText(name)
        }
        return .init(part: path, document: document, root: root, names: people)
    }

    private static func readThreadSheet(_ sheet: Sheet, links: [Relation], people: [String: String],
                                        legacy: XMLDocument?, package: Package) async throws -> ThreadSheet {
        let linksToComments = links.filter { isThreadRelationship($0) }
        let invalid = PetError("工作表的评论关系无法读取")
        guard linksToComments.count == 1, let link = linksToComments.first else { throw invalid }
        let path = try part(link.target, from: sheet.part)
        let document = try await package.xml(path)
        guard let root = document.rootElement(), root.localName == "ThreadedComments", root.uri == threadURI else { throw invalid }
        let nodes = children(root, "threadedComment").filter { $0.uri == threadURI }
        guard !nodes.isEmpty, nodes.count <= limit else { throw invalid }
        var seen: Set<String> = []
        let messages = try nodes.map { node -> ThreadMessageNode in
            let rawParent = attribute(node, "parentId"), parent = threadID(rawParent)
            guard let id = threadID(attribute(node, "id")), let personID = threadID(attribute(node, "personId")),
                  rawParent == nil || parent != nil, seen.insert(id).inserted else { throw invalid }
            let name = people[personID]
            let text = decodeThreadText(children(node, "text").first?.stringValue ?? "")
            let message = AgentSpreadsheetThread.Message(id: id, parent: parent, author: name.flatMap { $0.isEmpty ? nil : $0 } ?? "未知作者",
                                                         time: attribute(node, "dT"), text: text)
            return .init(message: message, xml: node, knownAuthor: name != nil)
        }
        let replies = Dictionary(grouping: messages, by: \.message.parent)
        let placeholders = threadPlaceholders(legacy)
        var visited = 0
        let entries = try (replies[nil] ?? []).map { entry -> ThreadSheet.Entry in
            let id = entry.message.id
            let anchors = placeholders[id] ?? []
            guard let cell = anchors.first ?? attribute(entry.xml, "ref"), validCell(cell) else { throw invalid }
            let done = attribute(entry.xml, "done") ?? "0"
            guard ["0", "1", "false", "true"].contains(done) else { throw invalid }
            var pending = [entry], members: [ThreadMessageNode] = []
            while let next = pending.popLast() {
                members.append(next)
                pending.append(contentsOf: (replies[next.message.id] ?? []).reversed())
            }
            visited += members.count
            let xml = members.map { $0.xml.xmlString(options: [.nodePreserveAll]) }.joined(separator: "\n")
            let version = AgentFiles.hash(Data(xml.utf8))
            let canEdit = anchors.count == 1 && members.allSatisfy(\.knownAuthor)
            let thread = AgentSpreadsheetThread(id: id, sheet: sheet.name, cell: cell, version: version,
                                                resolved: done == "1" || done == "true", editable: canEdit, messages: members.map(\.message))
            return .init(value: thread, root: entry.xml)
        }
        guard visited == messages.count else { throw invalid }
        return .init(part: path, kind: link.kind, document: document, root: root, entries: entries, ids: seen)
    }

    private static func legacyCommentCells(_ legacy: XMLDocument?) throws -> Set<String> {
        let comments = children(children(legacy?.rootElement(), "commentList").first, "comment")
        let addresses = Set(comments.compactMap { attribute($0, "ref") })
        guard addresses.count == comments.count, comments.count <= limit, addresses.allSatisfy(validCell) else {
            throw PetError("原工作簿的备注位置无法读取")
        }
        return addresses
    }

    private static func threadPlaceholders(_ legacy: XMLDocument?) -> [String: [String]] {
        let root = legacy?.rootElement()
        let authors = children(children(root, "authors").first, "author").map { threadPlaceholderID($0.stringValue ?? "") }
        var anchors: [String: [String]] = [:]
        for node in children(children(root, "commentList").first, "comment") {
            guard let author = attribute(node, "authorId").flatMap(Int.init), authors.indices.contains(author),
                  let id = authors[author], let cell = attribute(node, "ref"), validCell(cell) else { continue }
            anchors[id, default: []].append(cell)
        }
        return anchors
    }

    private static func addMessage(_ message: AgentSpreadsheetThreadEdit.Reply, parent: String?, cell: String,
                                   to root: XMLElement) -> XMLElement {
        let element = appendThreadItem("threadedComment", to: root)
        set("id", message.id, on: element)
        if let parent { set("parentId", parent, on: element) }
        set("ref", cell, on: element)
        set("personId", localThreadAuthor, on: element)
        set("dT", message.time, on: element)
        append("text", to: element).stringValue = encodeThreadText(message.text)
        return element
    }

    private static func appendThreadItem(_ name: String, to root: XMLElement) -> XMLElement {
        let index = root.children?.firstIndex { $0.localName == "extLst" && $0.uri == threadURI }
        let item = append(name, to: root)
        if let index { item.detach(); root.insertChild(item, at: index) }
        return item
    }

    private static func decodeThreadText(_ text: String) -> String {
        let value = text as NSString
        let matches = escapedText.matches(in: text, range: NSRange(location: 0, length: value.length))
        guard !matches.isEmpty else { return text }
        var units: [UInt16] = [], end = 0
        for match in matches {
            units.append(contentsOf: value.substring(with: NSRange(location: end, length: match.range.location - end)).utf16)
            if let character = UInt16(value.substring(with: match.range(at: 1)), radix: 16) { units.append(character) }
            end = NSMaxRange(match.range)
        }
        units.append(contentsOf: value.substring(from: end).utf16)
        return String(decoding: units, as: UTF16.self)
    }

    private static func encodeThreadText(_ text: String) -> String {
        text.replacingOccurrences(of: "_x(?=[0-9a-fA-F]{4}_)", with: "_x005F_x", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "_x000D_")
    }
}
