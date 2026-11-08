import Foundation

enum AgentMode: String, Codable, CaseIterable {
    case ask, plan, agent, goal
    var title: String { switch self { case .ask: return "问答"; case .plan: return "计划"; case .agent: return "Agent"; case .goal: return "目标" } }
}
enum AgentTaskStatus: String, Codable {
    case ready, running, waiting, stopped, completed, failed
    var title: String {
        switch self { case .ready: return "待开始"; case .running: return "执行中"; case .waiting: return "需要我"; case .stopped: return "已停止"; case .completed: return "已完成"; case .failed: return "出错了" }
    }
}
enum AgentPermissionMode: String, Codable, CaseIterable {
    case review, workspace, automatic
    var title: String { switch self { case .review: return "逐次确认"; case .workspace: return "允许项目修改"; case .automatic: return "自动执行" } }
}
struct AgentToolCall: Codable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var displayName: String?
    var originalArguments: String?
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:] }
    var wire: [String: Any] { ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]] }
}
struct AgentMessage: Codable, Identifiable {
    var id = UUID().uuidString
    var role: String
    var content: String
    var reasoning: String?
    var toolCalls: [AgentToolCall]?
    var toolCallID: String?
    var attachmentIDs: [String]?
    var nativeContext: Bool?
    var importedContext: Bool?
    var visuals: [AgentVisualPart]?
    var visualsDelivered: Bool?
    var extensionInstructions: String?
    var extensionReferences: [AgentExtensionReference]?
    var hookRejected: Bool?
    var isHumanInput: Bool { role == "user" && nativeContext != true && hookRejected != true }
    var isImportedContext: Bool { nativeContext == true && (importedContext == true || content.hasPrefix("[Codex历史记录，仅作资料") || content.hasPrefix("[Qoder历史记录，仅作资料")) }
    var wire: [String: Any] {
        let references = (attachmentIDs ?? []).isEmpty ? "" : "\n[附件编号：" + (attachmentIDs ?? []).joined(separator: ", ") + "]"
        var value: [String: Any] = ["role": role, "content": content + references + (extensionInstructions.map { "\n\n" + $0 } ?? "")]
        if let reasoning { value["reasoning_content"] = reasoning }
        if let toolCalls, !toolCalls.isEmpty { value["tool_calls"] = toolCalls.map(\.wire) }
        if let toolCallID { value["tool_call_id"] = toolCallID }
        return value
    }
}
struct AgentEvent: Codable, Identifiable {
    var id = UUID().uuidString
    var kind: String
    var title: String
    var detail = ""
    var status = "running"
    var created = Date()
    var duration: Double?
    var toolCallID: String?
    var hook: AgentHookExecution?
    var childTaskID: String?
    var statusTitle: String { ["running": "运行中", "completed": "已完成", "failed": "失败", "stopped": "已停止", "blocked": "已拦截", "waiting": "待确认", "imported": "历史记录"][status] ?? status }
}
struct AgentPlanStep: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var status = "pending"
}
struct AgentChange: Codable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var existed: Bool
    var backup: String?
    var beforeHash: String?
    var afterHash: String?
    var permissions: Int?
    var beforeKind: String?
    var afterKind: String?
    var afterPermissions: Int?
    var origin: String?
    var reviewOnly: Bool?
    var restoredAt: Date?
    var created = Date()
}
struct AgentApproval: Codable, Identifiable {
    var id = UUID().uuidString
    var call: AgentToolCall
    var reason: String
    var workspace: String?
    var gitDirectory: String?
    var intentID: String?
    var decision: String?
    var answerAttachments: [String]?
    var answerMessage: AgentMessage?
    var created = Date()
}
struct AgentTaskRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var workspace: String?
    var workMode: AgentWorkMode?
    var organizationMode: AgentWorkMode { workMode ?? .coding }
    var importOrigin: AgentImportOrigin?
    var mode = AgentMode.agent
    var permission = AgentPermissionMode.workspace
    var status = AgentTaskStatus.ready
    var messages: [AgentMessage] = []
    var events: [AgentEvent] = []
    var plan: [AgentPlanStep] = []
    var changes: [AgentChange] = []
    var approvals: [AgentApproval] = []
    var pendingCalls: [AgentToolCall] = []
    var artifacts: [String] = []
    var sources: [String] = []
    var summary = ""
    var archived = false, pinned = false
    var parentID: String?
    var model = ""
    var modelOverride: String?
    var modelReceipts: [AgentModelReceipt]?
    var contextSnapshot: AgentContextSnapshot?
    var recap: AgentTaskRecap?
    var toolGroups: [String]?
    var draft: String?
    var kind: String?
    var queuedInputs: [String]?
    var queuedMessages: [AgentMessage]?
    var goalAccepted: Bool?
    var completionEvidence: [String]?
    var contextSummary: String?
    var contextThroughID: String?
    var contextManualThroughID: String?
    var contextSize: Int?
    var gitDirectory: String?
    var gitReview: AgentGitReview?
    var worktreeOrigin: AgentWorktreeOrigin?
    var gitTurn: AgentGitTurn?
    var pendingFileCapture: AgentFileCapture?
    var gitPushReview: AgentGitPushReview?
    var gitPushReceipt: AgentGitPushReceipt?
    var gitRemoteSnapshot: AgentGitRemoteSnapshot?
    var wikiRevision: String?
    var attachments: [AgentAttachment]?
    var canvases: [AgentCanvasRecord]?
    var draftAttachmentIDs: [String]?
    var activeSkills: [AgentExtensionReference]?
    var hookSession: String?, hookCwd: String?
    var hookContexts: [String: String]?, hookRejectedAnswers: [AgentMessage]?
    var hookStopBlocks: Int?
    var hookRewakePromptID: String?, hookRewakeCount: Int?
    var hookPromptIDs: [String]?, hookContextIDs: [String]?
    var hookTools: [String]?, hookNetwork: Bool?
    var agent: AgentProfileAssignment?
    var team: AgentTeamAssignment?
    var automation: AgentAutomationAssignment?
    var canChooseExecutor: Bool {
        status == .ready && !archived && messages.isEmpty && events.isEmpty && pendingCalls.isEmpty && agent?.ownerID == nil && automation == nil && kind != "hook" && kind != "wiki"
    }
    var canChooseEnvironment: Bool {
        status == .ready && !archived && !messages.contains(where: { $0.isHumanInput || $0.role == "assistant" }) && pendingCalls.isEmpty && agent?.ownerID == nil && automation == nil && kind != "hook" && kind != "wiki"
    }
    var workspaceDisplayName: String? {
        if let origin = worktreeOrigin { return URL(fileURLWithPath: origin.root).lastPathComponent + " · 工作树" }
        return workspace.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
    var inputTokens = 0, outputTokens = 0
    var created = Date(), updated = Date()
    var statusTitle: String {
        if kind == "hook", status == .completed {
            if summary.hasPrefix("未通过：") { return "校验未通过" }
            if summary.hasPrefix("通过：") { return "校验通过" }
        }
        return status.title
    }
    var queuedCount: Int { (queuedInputs?.count ?? 0) + (queuedMessages?.count ?? 0) }
    var submittedAttachmentIDs: Set<String> { Set(messages.filter(\.isHumanInput).flatMap { $0.attachmentIDs ?? [] }) }
    var availableAttachmentIDs: Set<String> {
        let captures = Set((attachments ?? []).filter { $0.browserCapture != nil || $0.desktopCapture != nil || $0.canvasCapture != nil }.map(\.id))
        let observed = Set(messages.filter { $0.role == "tool" }.flatMap { ($0.visuals ?? []).map(\.id) })
        let mcp = Set((attachments ?? []).filter { $0.mcpSource != nil }.map(\.id))
        let received = Set(messages.filter { $0.role == "tool" }.flatMap { $0.attachmentIDs ?? [] })
        return submittedAttachmentIDs.union(captures.intersection(observed)).union(mcp.intersection(received))
    }
    var hasUndeliveredVisuals: Bool { messages.contains { $0.role == "tool" && $0.visualsDelivered == false && $0.visuals?.isEmpty == false } }
    mutating func flushQueuedInputs() {
        let pending = (queuedInputs ?? []).map { AgentMessage(role: "user", content: $0) } + (queuedMessages ?? [])
        for message in pending { activateExtensions(message) }; messages += pending
        queuedInputs = []; queuedMessages = []
    }
    mutating func activateExtensions(_ message: AgentMessage) {
        for reference in message.extensionReferences ?? [] where reference.kind == .skill {
            if activeSkills == nil { activeSkills = [] }
            activeSkills?.removeAll { $0.id == reference.id }; activeSkills?.append(reference)
        }
    }
}
struct AgentTurn {
    var content = "", reasoning = ""
    var calls: [AgentToolCall] = []
    var inputTokens = 0, outputTokens = 0
    var finishReason = ""
    var returnedModel: String?
    var inputTokensReported = false, outputTokensReported = false
}
struct AgentToolResult {
    var text: String
    var failed = false
    var artifacts: [String] = []
    var sources: [String] = []
    var stdout: String?
    var stdoutData: Data?
    var stderr: String?
    var exitCode: Int?
    var truncated: Bool?
    var timedOut = false
    var visuals: [AgentVisualPart]?
    var extensionReferences: [AgentExtensionReference]?
    var attachmentIDs: [String]?
}
