import Foundation

struct AgentModelReceipt: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date()
    var purpose: String
    var requestedModel: String
    var returnedModel: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var finishReason: String
    var duration: Double
    var completed: Bool
    var messageID: String?
    var purposeTitle: String {
        switch purpose { case "compaction": return "上下文压缩"; case "recap": return "任务回顾"; case "suggestions": return "提示建议"; case "skill_evolution": return "Skill 自进化建议"; case "validation": return "Hook 校验"; default: return "对话" }
    }
}

struct AgentContextSnapshot: Codable {
    struct Part: Codable { var title: String; var tokens: Int }
    var created = Date()
    var model: String
    var limit: Int
    var outputReserve: Int
    var parts: [Part]
    var loadedSkills: Int
    var estimatedTokens: Int { parts.reduce(0) { $0 + $1.tokens } }
}

struct AgentTaskRecap: Codable {
    var created = Date()
    var model: String
    var throughMessageID: String?
    var text: String
}

@MainActor final class AgentTaskModels {
    private struct Catalog: Codable { var endpoint: String; var updated: Date; var models: [ModelInfo] }
    private let file: URL
    private var catalog: Catalog?
    init(profile: URL) {
        file = profile.appendingPathComponent("models/catalog.json")
        if let data = try? Data(contentsOf: file), data.count <= 4_000_000 { catalog = try? JSONDecoder().decode(Catalog.self, from: data) }
    }
    private func endpoint(_ p: PetPreferences) -> String { (try? CompanionService.endpoint(p.endpoint, chat: true).absoluteString) ?? "" }
    func models(_ p: PetPreferences) -> [ModelInfo] { catalog?.endpoint == endpoint(p) ? catalog?.models ?? [] : [] }
    func resolve(_ base: PetPreferences, task: AgentTaskRecord) throws -> PetPreferences {
        var p = base
        if let override = task.modelOverride { p.model = override }
        else if let role = task.agent?.profile.model, !role.isEmpty { p.model = role }
        else if task.automation != nil, !task.model.isEmpty { p.model = task.model }
        if p.currentModelInfo == nil { p.modelInfo = models(p).first { $0.id == p.model } }
        try p.validateModel()
        return p
    }
    func refresh(_ p: PetPreferences, key: String) async throws {
        let values = try await CompanionService.models(endpoint: p.endpoint, key: key)
        let cleaned = values.filter { Self.validID($0.id) }
        guard !cleaned.isEmpty else { throw PetError("服务未返回可用模型，可直接输入模型 ID") }
        let value = Catalog(endpoint: endpoint(p), updated: Date(), models: cleaned)
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        catalog = value
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count < 200 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

extension AgentStore {
    func recordUsage(_ id: String, _ receipt: AgentModelReceipt, persist: Bool = true) {
        guard task(id) != nil else { return }
        update(id, persist: persist) { record in
            if record.modelReceipts == nil { record.modelReceipts = [] }
            guard record.modelReceipts?.contains(where: { $0.id == receipt.id }) != true else { return }
            record.modelReceipts?.append(receipt)
            record.inputTokens += receipt.inputTokens ?? 0
            record.outputTokens += receipt.outputTokens ?? 0
        }
    }
}
