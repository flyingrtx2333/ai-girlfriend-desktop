import Foundation

enum AgentPowerPointComments {
    private typealias OfficePackage = AgentSpreadsheetNotes
    private static let presentationURI = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relationshipURI = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let modernURI = "http://schemas.microsoft.com/office/powerpoint/2018/8/main"
    private static let relationType = "http://schemas.microsoft.com/office/2018/10/relationships/comments"
    private static let extensionID = "{6950BFC3-D8DA-4A85-94F7-54DA5524770B}"

    static func ensureSlideLinks(in file: URL) async throws {
        let package = try await OfficePackage.Package(file)
        let roots = try await package.relationships("").filter { $0.kind == "officeDocument" }
        guard roots.count == 1, let root = roots.first else { throw invalidLinks() }
        let presentation = try OfficePackage.part(root.target, from: "")
        let manifest = try await package.xml(presentation)
        guard let deck = manifest.rootElement(), deck.localName == "presentation", deck.uri == presentationURI else { throw invalidLinks() }
        let ids = children(children(deck, "sldIdLst").first, "sldId")
        let slides = try await package.relationships(presentation).filter { $0.kind == "slide" }
        let targets = Dictionary(uniqueKeysWithValues: slides.map { ($0.id, $0.target) })
        var updates: [String: XMLDocument] = [:]
        for entry in ids {
            try Task.checkCancellation()
            guard let id = entry.attribute(forLocalName: "id", uri: relationshipURI)?.stringValue,
                  let target = targets[id] else { throw invalidLinks() }
            let slidePath = try OfficePackage.part(target, from: presentation)
            let links = try await package.relationships(slidePath).filter { $0.type == relationType }
            guard let link = links.first else { continue }
            guard links.count == 1, package.entries.contains(try OfficePackage.part(link.target, from: slidePath)) else { throw invalidLinks() }
            let slide = try await package.xml(slidePath)
            guard let slideRoot = slide.rootElement(), slideRoot.localName == "sld", slideRoot.uri == presentationURI else { throw invalidLinks() }
            if try setSlideLink(link.id, on: slideRoot) { updates[slidePath] = slide }
        }
        if !updates.isEmpty { try await OfficePackage.write(updates, to: package) }
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
