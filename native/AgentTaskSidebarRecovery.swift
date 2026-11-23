import Foundation

struct AgentTaskSidebarRecovery: Codable, Equatable, Sendable {
    struct Search: Codable, Equatable, Sendable {
        var query: String
        var selectedTask: String?
        // The field editor owns this selection only when search has focus.
        var selection: AgentTextViewport.Selection?
    }

    struct Position: Codable, Equatable, Sendable {
        var row: String?
        var offset: Double
        var y: Double
    }

    struct State: Codable, Equatable, Sendable {
        var mode: AgentWorkMode
        var filter: Int
        var collapsedGroups: [String]
        var expandedTasks: [String]
        var search: Search?
        var position: Position?
    }

    var version = 1
    var windowID: String
    var state: State

    var valid: Bool {
        version == 1 && UUID(uuidString: windowID) != nil && (0...3).contains(state.filter) &&
            state.collapsedGroups.allSatisfy { !$0.isEmpty && $0.utf8.count <= 16_400 && !$0.contains("\0") } &&
            state.expandedTasks.allSatisfy { UUID(uuidString: $0) != nil } &&
            state.search.map { search in
                search.query.utf8.count <= 65_536 &&
                    (search.selectedTask.map { UUID(uuidString: $0) != nil } ?? true) &&
                    search.selection?.valid(in: search.query.utf16.count) != false
            } != false &&
            state.position.map { position in
                AgentSettingsRecovery.validScroll(position.y) && position.offset.isFinite && abs(position.offset) <= 128 &&
                    (position.row.map { !$0.isEmpty && $0.utf8.count <= 16_416 && !$0.contains("\0") } ?? true)
            } != false
    }

    static func validateObject(_ raw: Any) throws {
        func keys(_ raw: Any, _ allowed: Set<String>) throws -> [String: Any] {
            guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
                throw PetError("任务侧栏位置格式不受支持")
            }
            return object
        }
        let record = try keys(raw, ["version", "windowID", "state"])
        let state = try keys(record["state"] ?? NSNull(), ["mode", "filter", "collapsedGroups", "expandedTasks", "search", "position"])
        if let position = state["position"], !(position is NSNull) { _ = try keys(position, ["row", "offset", "y"]) }
        if let search = state["search"], !(search is NSNull) {
            let search = try keys(search, ["query", "selectedTask", "selection"])
            if let selection = search["selection"], !(selection is NSNull) { _ = try keys(selection, ["location", "length"]) }
        }
    }
}
