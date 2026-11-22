import Foundation

struct AgentAttentionRecovery: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var version = 1
        let windowID: String, layoutHash: String
        let state: AgentAttentionRecovery
    }
    struct Position: Codable, Equatable, Sendable {
        var anchor: String?
        var y: Double, offset: Double
        var valid: Bool {
            anchor.map(AgentAttentionRecovery.validID) != false &&
            AgentSettingsRecovery.validScroll(y) && offset.isFinite && abs(offset) <= 1_000_000_000
        }
    }
    struct List: Codable, Equatable, Sendable {
        var query = "", kind: String?, source: String?, sender: String?
        var days = 0, limit = 50
        var item: String?, position: Position?, selection: AgentTextViewport.Selection?
        var valid: Bool {
            query.utf8.count <= 1_000_000 && !query.contains("\0") &&
            kind.map { AgentAttentionKind(rawValue: $0) != nil } != false &&
            source.map { AgentAttentionSource(rawValue: $0) != nil } != false &&
            sender.map { !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\0") } != false &&
            [0, 1, 7, 30].contains(days) && (50...500_000).contains(limit) && limit.isMultiple(of: 50) &&
            item.map(AgentAttentionRecovery.validID) != false && position?.valid != false &&
            selection?.valid(in: query.utf16.count) != false
        }
    }
    struct Detail: Codable, Equatable, Sendable {
        var item: String, request: String?
        var reading: Bool
        var body: AgentTextViewport?, reply: AgentTextViewport?
        var valid: Bool {
            AgentAttentionRecovery.validID(item) && request.map { AgentSettingsRecovery.validHash($0) } != false &&
            body?.valid != false && reply?.valid != false
        }
    }
    enum Focus: String, Codable, Sendable { case search, list, body, reply }
    var version = 1
    var active: Bool
    var tab: Int
    var lists: [List]
    var detail: Detail?
    var focus: Focus?
    var valid: Bool {
        version == 1 && lists.count == 2 && lists.indices.contains(tab) && lists.allSatisfy(\.valid) &&
        detail.map { $0.valid && $0.item == lists[tab].item } != false
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\0")
    }
    static func validateObject(_ raw: Any) throws {
        let invalid = PetError("需要我恢复格式不受支持，原记录已保留")
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw invalid }
            return value
        }
        let value = try object(raw, keys: ["version", "active", "tab", "lists", "detail", "focus"])
        guard let lists = value["lists"] as? [Any] else { throw invalid }
        for rawList in lists {
            let list = try object(rawList, keys: ["query", "kind", "source", "sender", "days", "limit", "item", "position", "selection"])
            if let position = list["position"], !(position is NSNull) { _ = try object(position, keys: ["anchor", "y", "offset"]) }
            if let selection = list["selection"], !(selection is NSNull) { _ = try object(selection, keys: ["location", "length"]) }
        }
        if let rawDetail = value["detail"], !(rawDetail is NSNull) {
            let detail = try object(rawDetail, keys: ["item", "request", "reading", "body", "reply"])
            for key in ["body", "reply"] {
                if let viewport = detail[key], !(viewport is NSNull) { try AgentTextViewport.validateObject(viewport) }
            }
        }
    }
}
