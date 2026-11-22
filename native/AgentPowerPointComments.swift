import Foundation

enum AgentPowerPointComments {
    private typealias OfficePackage = AgentSpreadsheetNotes
    private static let presentationURI = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relationshipURI = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let modernURI = "http://schemas.microsoft.com/office/powerpoint/2018/8/main"
    private static let relationType = "http://schemas.microsoft.com/office/2018/10/relationships/comments"
    private static let extensionID = "{6950BFC3-D8DA-4A85-94F7-54DA5524770B}"
    private static let threadingURI = "http://schemas.microsoft.com/office/powerpoint/2012/main"
    private static let threadingID = "{C676402C-5697-4E1C-873F-D02D1690AC5C}"

    struct LegacyReplyLink: Decodable {
        struct Identifier: Decodable, Hashable {
            let author: UInt32, index: UInt32
        }
        struct Anchor: Decodable {
            let signature: String, source: Identifier?
        }
        let slide: Int, reply: Anchor, parent: Anchor
    }
    private struct LegacyComment {
        let id: LegacyReplyLink.Identifier, signature: String, node: XMLElement
    }

    static func ensureSlideLinks(in file: URL) async throws {
        let package = try await OfficePackage.Package(file)
        let (_, paths) = try await slideParts(in: package)
        var updates: [String: XMLDocument] = [:]
        for slidePath in paths {
            try Task.checkCancellation()
            let links = try await package.relationships(slidePath).filter { $0.type == relationType }
            guard let link = links.first else { continue }
            guard links.count == 1, package.entries.contains(try OfficePackage.part(link.target, from: slidePath)) else { throw invalidLinks() }
            let slide = try await package.xml(slidePath)
            guard let slideRoot = slide.rootElement(), slideRoot.localName == "sld", slideRoot.uri == presentationURI else { throw invalidLinks() }
            if try setSlideLink(link.id, on: slideRoot) { updates[slidePath] = slide }
        }
        if !updates.isEmpty { try await OfficePackage.write(updates, to: package) }
    }

    static func attachLegacyReplies(_ edits: [LegacyReplyLink], in file: URL) async throws {
        guard !edits.isEmpty else { return }
        let package = try await OfficePackage.Package(file)
        let (presentation, slides) = try await slideParts(in: package)
        let authorPart = try await legacyPart("commentAuthors", of: presentation, in: package)
        let authorDocument = try await package.xml(authorPart)
        guard let authorList = authorDocument.rootElement(), authorList.localName == "cmAuthorLst",
              authorList.uri == presentationURI else { throw invalidLinks() }
        var authors: [UInt32: String] = [:]
        for author in children(authorList, "cmAuthor") {
            guard let id = integer("id", on: author), authors[id] == nil,
                  let name = OfficePackage.attribute(author, "name") else { throw invalidLinks() }
            authors[id] = name
        }
        var updates: [String: XMLDocument] = [:]
        for (number, changes) in Dictionary(grouping: edits, by: \.slide) {
            try Task.checkCancellation()
            guard number > 0, slides.indices.contains(number - 1) else { throw invalidLinks() }
            let part = try await legacyPart("comments", of: slides[number - 1], in: package)
            guard updates[part] == nil else { throw invalidLinks() }
            let document = try await package.xml(part)
            guard let list = document.rootElement(), list.localName == "cmLst", list.uri == presentationURI else { throw invalidLinks() }
            let comments = try children(list, "cm").map { comment -> LegacyComment in
                guard let author = integer("authorId", on: comment), let index = integer("idx", on: comment),
                      let name = authors[author], let text = children(comment, "text").first else { throw invalidLinks() }
                let values = [name, OfficePackage.attribute(comment, "dt") ?? "", text.stringValue ?? ""]
                return .init(id: .init(author: author, index: index),
                             signature: AgentFiles.hash(Data(values.joined(separator: "\0").utf8)), node: comment)
            }
            guard Set(comments.map(\.id)).count == comments.count else { throw invalidLinks() }
            let bySignature = Dictionary(grouping: comments, by: \.signature)
            func locate(_ anchor: LegacyReplyLink.Anchor) throws -> LegacyComment {
                let matches = (bySignature[anchor.signature] ?? []).filter { anchor.source == nil || anchor.source == $0.id }
                guard matches.count == 1, let comment = matches.first else { throw invalidLinks() }
                return comment
            }
            let links = try changes.map { (reply: try locate($0.reply), parent: try locate($0.parent)) }
            let replies = Set(links.map { $0.reply.id })
            guard replies.count == links.count, links.allSatisfy({ !replies.contains($0.parent.id) }) else { throw invalidLinks() }
            for link in links {
                try attach(parent: link.parent, to: link.reply.node)
            }
            updates[part] = document
        }
        try await OfficePackage.write(updates, to: package)
    }

    private static func legacyPart(_ kind: String, of owner: String, in package: OfficePackage.Package) async throws -> String {
        let links = try await package.relationships(owner).filter { $0.type == relationshipURI + "/" + kind }
        guard links.count == 1, let link = links.first else { throw invalidLinks() }
        return try OfficePackage.part(link.target, from: owner)
    }

    private static func integer(_ name: String, on node: XMLElement) -> UInt32? {
        OfficePackage.attribute(node, name).flatMap { UInt32($0) }
    }

    private static func threading(_ comment: XMLElement) throws -> (list: XMLElement?, entry: XMLElement?, info: XMLElement?, parent: XMLElement?) {
        let lists = children(comment, "extLst")
        let entries = children(lists.first, "ext").filter { OfficePackage.attribute($0, "uri")?.uppercased() == threadingID }
        let nodes = OfficePackage.children(entries.first, "threadingInfo").filter { $0.uri == threadingURI }
        let parents = OfficePackage.children(nodes.first, "parentCm").filter { $0.uri == threadingURI }
        guard lists.count <= 1, entries.count <= 1, nodes.count <= 1, parents.count <= 1 else { throw invalidLinks() }
        return (lists.first, entries.first, nodes.first, parents.first)
    }

    private static func attach(parent: LegacyComment, to reply: XMLElement) throws {
        guard try threading(parent.node).parent == nil else { throw invalidLinks() }
        let existing = try threading(reply)
        if let current = existing.parent {
            guard integer("authorId", on: current) == parent.id.author, integer("idx", on: current) == parent.id.index else { throw invalidLinks() }
            return
        }
        let list = existing.list ?? append("extLst", to: reply, like: reply)
        let entry = existing.entry ?? append("ext", to: list, like: reply)
        if existing.entry == nil { OfficePackage.set("uri", threadingID, on: entry) }
        let info: XMLElement
        if let previous = existing.info { info = previous }
        else {
            info = XMLElement(name: "p15:threadingInfo")
            info.addNamespace(XMLNode.namespace(withName: "p15", stringValue: threadingURI) as! XMLNode)
            OfficePackage.set("timeZoneBias", "0", on: info)
            entry.addChild(info)
        }
        let prefix = info.prefix.map { $0 + ":" } ?? ""
        let reference = XMLElement(name: prefix + "parentCm")
        OfficePackage.set("authorId", String(parent.id.author), on: reference)
        OfficePackage.set("idx", String(parent.id.index), on: reference)
        info.addChild(reference)
    }

    private static func slideParts(in package: OfficePackage.Package) async throws -> (String, [String]) {
        let roots = try await package.relationships("").filter { $0.kind == "officeDocument" }
        guard roots.count == 1, let root = roots.first else { throw invalidLinks() }
        let presentation = try OfficePackage.part(root.target, from: "")
        let manifest = try await package.xml(presentation)
        guard let deck = manifest.rootElement(), deck.localName == "presentation", deck.uri == presentationURI else { throw invalidLinks() }
        let ids = children(children(deck, "sldIdLst").first, "sldId")
        let slides = try await package.relationships(presentation).filter { $0.kind == "slide" }
        let targets = Dictionary(uniqueKeysWithValues: slides.map { ($0.id, $0.target) })
        let paths = try ids.map { entry in
            guard let id = entry.attribute(forLocalName: "id", uri: relationshipURI)?.stringValue,
                  let target = targets[id] else { throw invalidLinks() }
            return try OfficePackage.part(target, from: presentation)
        }
        guard Set(paths).count == paths.count else { throw invalidLinks() }
        return (presentation, paths)
    }

    private static func setSlideLink(_ id: String, on slide: XMLElement) throws -> Bool {
        let lists = children(slide, "extLst")
        guard lists.count <= 1 else { throw invalidLinks() }
        let list = lists.first ?? append("extLst", to: slide, like: slide)
        let entries = children(list, "ext").filter { OfficePackage.attribute($0, "uri")?.uppercased() == extensionID }
        guard entries.count <= 1 else { throw invalidLinks() }
        let entry = entries.first ?? append("ext", to: list, like: slide)
        if entries.isEmpty { OfficePackage.set("uri", extensionID, on: entry) }
        let references = OfficePackage.children(entry, "commentRel").filter { $0.uri == modernURI }
        guard references.count <= 1 else { throw invalidLinks() }
        if let reference = references.first {
            if let attribute = reference.attribute(forLocalName: "id", uri: relationshipURI) {
                if attribute.stringValue == id { return false }
                attribute.stringValue = id
                return true
            }
            reference.detach()
        }
        let reference = XMLElement(name: "p188:commentRel")
        reference.addNamespace(XMLNode.namespace(withName: "p188", stringValue: modernURI) as! XMLNode)
        reference.addNamespace(XMLNode.namespace(withName: "r", stringValue: relationshipURI) as! XMLNode)
        OfficePackage.set("r:id", id, on: reference)
        entry.addChild(reference)
        return true
    }

    private static func children(_ parent: XMLElement?, _ localName: String) -> [XMLElement] {
        OfficePackage.children(parent, localName).filter { $0.uri == presentationURI }
    }

    private static func append(_ localName: String, to parent: XMLElement, like slide: XMLElement) -> XMLElement {
        let prefix = slide.prefix ?? ""
        let child = XMLElement(name: prefix.isEmpty ? localName : prefix + ":" + localName)
        parent.addChild(child)
        return child
    }

    private static func invalidLinks() -> PetError { PetError("演示文稿的批注关联无效，原文件及草稿已保留") }
}
