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
    var wire: [String: Any] {
        var value: [String: Any] = ["role": role, "content": content]
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
    var created = Date()
}
struct AgentTaskRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var workspace: String?
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
    var draft: String?
    var kind: String?
    var queuedInputs: [String]?
    var goalAccepted: Bool?
    var completionEvidence: [String]?
    var contextSummary: String?
    var contextThroughID: String?
    var contextSize: Int?
    var gitDirectory: String?
    var gitReview: AgentGitReview?
    var wikiRevision: String?
    var inputTokens = 0, outputTokens = 0
    var created = Date(), updated = Date()
}
struct AgentTurn {
    var content = "", reasoning = ""
    var calls: [AgentToolCall] = []
    var inputTokens = 0, outputTokens = 0
    var finishReason = ""
}
struct AgentToolResult {
    var text: String
    var failed = false
    var artifacts: [String] = []
    var sources: [String] = []
    var stdout: String?
    var stderr: String?
    var exitCode: Int?
    var truncated: Bool?
}
