import Foundation

struct AgentWorkspaceEditorDraft: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var version = 1
        let windowID: String
        let drafts: [String: AgentWorkspaceEditorDraft]

        var valid: Bool {
            version == 1 && UUID(uuidString: windowID)?.uuidString == windowID
                && drafts.allSatisfy { $0.key == $0.value.context.taskID && $0.value.valid }
        }

        static func validateObject(_ raw: Any) throws {
            let record = try AgentSettingsRecovery.object(raw, keys: ["version", "windowID", "drafts"])
            guard let drafts = record["drafts"] as? [String: Any] else { throw PetError("工作区设置草稿格式不受支持，原记录已保留") }
            for raw in drafts.values {
                let draft = try AgentSettingsRecovery.object(raw, keys: ["context", "original", "returnPage", "knowledgeRoot",
                    "name", "icon", "color", "folders", "primary", "folderIdentities", "scrollY", "nameFocused", "selection", "feedback"])
                if let context = draft["context"] { try AgentSettingsRecovery.validateContext(context) }
                if let original = draft["original"] {
                    _ = try AgentSettingsRecovery.object(original, keys: ["path", "mode", "name", "icon", "color", "folders",
                        "primaryFolder", "pinned", "created", "archiveID", "archivedAt"])
                }
                if let selection = draft["selection"], !(selection is NSNull) {
                    _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"])
                }
            }
        }
    }

    let context: AgentSettingsRecovery.Context
    let original: AgentDirectoryEntry
    let returnPage: String
    let knowledgeRoot: String?
    var name: String
    var icon: AgentWorkspaceIcon
    var color: AgentWorkspaceColor
    var folders: [String]
    var primary: String
    var folderIdentities: [String: String]
    var scrollY: Double
    var nameFocused: Bool
    var selection: AgentTextViewport.Selection?
    var feedback: String?

    private static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count < 8192 && !value.contains("\0")
    }
    private static func validScope(_ folders: [String], primary: String) -> Bool {
        (1...16).contains(folders.count) && Set(folders).count == folders.count && folders.contains(primary) && folders.allSatisfy(validPath)
    }
    var valid: Bool {
        context.taskID != nil && context.workspace == nil && context.valid
            && Self.validPath(original.path) && original.archiveID == nil && original.created.timeIntervalSinceReferenceDate.isFinite
            && original.name.map { $0.count <= 80 && !$0.contains("\0") } != false
            && Self.validScope(original.sourceFolders, primary: original.primary) && Self.validScope(folders, primary: primary)
            && ["chat", "attention", "automation", "knowledge"].contains(returnPage)
            && knowledgeRoot.map { returnPage == "knowledge" && ["library", "wiki"].contains($0) } != false
            && name.utf8.count <= 1_000_000 && !name.contains("\0")
            && folderIdentities.allSatisfy { (folders.contains($0.key) || original.path == $0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 128 && !$0.value.contains("\0") }
            && AgentSettingsRecovery.validScroll(scrollY) && selection?.valid(in: name.utf16.count) != false
            && feedback.map { $0.utf8.count <= 8192 && !$0.contains("\0") } != false
    }
}
