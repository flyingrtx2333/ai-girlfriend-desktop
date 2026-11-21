import Foundation

struct ModelInfo: Codable, Equatable, Sendable {
    var endpoint: String
    var id: String
    var name: String?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var vision: Bool?
    var reasoningLevels: [String]?

    init?(endpoint: String, object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty, id.count < 200 else { return nil }
        self.endpoint = endpoint; self.id = id; name = object["name"] as? String
        if let value = object["context_window"] as? Int, (1024...16_777_216).contains(value) { contextWindow = value }
        if let value = object["max_output_tokens"] as? Int, value > 0 { maxOutputTokens = value }
        if let modalities = object["input_modalities"] as? [String] { vision = modalities.contains("image") }
        if let effort = object["effort"] as? [String: Any], let levels = effort["supported_levels"] as? [String] {
            reasoningLevels = levels.filter { ["minimal", "low", "medium", "high", "xhigh", "max"].contains($0) }
        }
    }
}

struct AgentModelSettingsRecovery: Codable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable { case endpoint, model, context, reply }

    struct Form: Codable, Equatable, Sendable {
        var endpoint: String, model: String, context: String, reply: String
        var vision: Int, reasoning: Int

        subscript(_ field: Field) -> String {
            switch field {
            case .endpoint: return endpoint
            case .model: return model
            case .context: return context
            case .reply: return reply
            }
        }

        var values: [String] { Field.allCases.map { self[$0] } + [String(vision), String(reasoning)] }
        var provider: String? { try? CompanionService.endpoint(endpoint, chat: true).absoluteString }
        var valid: Bool {
            values.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") } && provider != nil &&
                (0...2).contains(vision) && (0...7).contains(reasoning)
        }
    }

    struct Draft: Codable, Equatable, Sendable {
        let base: String
        let form: Form
        let focus: Field?
        let selection: AgentTextViewport.Selection?

        var valid: Bool {
            AgentSettingsRecovery.validHash(base) && form.valid &&
                (selection == nil || focus.flatMap { selection?.valid(in: form[$0].utf16.count) } == true)
        }

        static func fingerprint(_ preferences: PetPreferences) -> String? {
            struct Saved: Encodable {
                let endpoint: String, model: String, vision: String, reasoning: String
                let context: Int, reply: Int
                let info: ModelInfo?
            }
            let saved = Saved(endpoint: preferences.endpoint, model: preferences.model, vision: preferences.visionMode,
                reasoning: preferences.reasoningEffort, context: preferences.contextTokens, reply: preferences.replyTokens, info: preferences.currentModelInfo)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(saved)).map(AgentFiles.hash)
        }
    }

    struct Directory: Codable, Equatable, Sendable {
        enum Focus: String, Codable, Sendable { case search, list }
        var provider: String?
        var models: [ModelInfo]
        var query: String, selection: AgentTextViewport.Selection?, selected: String?
        var y: Double
        var focus: Focus

        var valid: Bool {
            query.utf8.count <= 4096 && !query.contains("\0") && selection?.valid(in: query.utf16.count) != false &&
                selected.map(AgentTaskModels.validID) != false && AgentSettingsRecovery.validScroll(y) && models.count <= 500 &&
                Set(models.map(\.id)).count == models.count && models.allSatisfy { $0.endpoint == provider && Self.safe($0) } &&
                provider.map { $0.utf8.count <= 16_384 && (try? CompanionService.endpoint($0, chat: true).absoluteString) == $0 } != false
        }

        static func cache(_ models: [ModelInfo], provider: String?) -> [ModelInfo] {
            guard let provider, models.count <= 500 else { return [] }
            return models.compactMap { original in
                var info = original
                info.name = original.name.map { String($0.prefix(200)) }
                info.reasoningLevels = original.reasoningLevels.map { Array(Set($0)).sorted() }
                return info.endpoint == provider && safe(info) ? info : nil
            }
        }

        private static func safe(_ info: ModelInfo) -> Bool {
            AgentTaskModels.validID(info.id) && info.id.utf8.count <= 4096 &&
                info.name.map { $0.utf8.count <= 4096 && !$0.contains("\0") } != false &&
                info.contextWindow.map { (1024...16_777_216).contains($0) } != false && info.maxOutputTokens.map { $0 > 0 } != false &&
                info.reasoningLevels.map { $0.count <= 6 && Set($0).isSubset(of: ["minimal", "low", "medium", "high", "xhigh", "max"]) } != false
        }
    }

    var draft: Draft?
    var directory: Directory?
    var valid: Bool { (draft != nil || directory != nil) && draft?.valid != false && directory?.valid != false }

    static func validateObject(_ raw: Any) throws {
        func selection(_ value: Any?) throws {
            if let value, !(value is NSNull) { _ = try AgentSettingsRecovery.object(value, keys: ["location", "length"]) }
        }
        let object = try AgentSettingsRecovery.object(raw, keys: ["draft", "directory"])
        if let raw = object["draft"], !(raw is NSNull) {
            let draft = try AgentSettingsRecovery.object(raw, keys: ["base", "form", "focus", "selection"])
            _ = try AgentSettingsRecovery.object(draft["form"] ?? NSNull(), keys: ["endpoint", "model", "context", "reply", "vision", "reasoning"])
            try selection(draft["selection"])
        }
        if let raw = object["directory"], !(raw is NSNull) {
            let directory = try AgentSettingsRecovery.object(raw, keys: ["provider", "models", "query", "selection", "selected", "y", "focus"])
            for model in directory["models"] as? [Any] ?? [] {
                _ = try AgentSettingsRecovery.object(model, keys: ["endpoint", "id", "name", "contextWindow", "maxOutputTokens", "vision", "reasoningLevels"])
            }
            try selection(directory["selection"])
        }
    }
}

enum TokenPreview {
    static func mask(_ value: String) -> String {
        if value.count > 28 { return String(value.prefix(12)) + " … " + String(value.suffix(12)) }
        if value.count > 12 { return String(value.prefix(4)) + " … " + String(value.suffix(4)) }
        return "••••••••"
    }
}

extension PetPreferences {
    var currentModelInfo: ModelInfo? {
        guard let info = modelInfo, info.id == model,
              info.endpoint == (try? CompanionService.endpoint(endpoint, chat: true).absoluteString) else { return nil }
        return info
    }
    var visionSupported: Bool? { visionMode == "on" ? true : visionMode == "off" ? false : currentModelInfo?.vision }
    var contextLimit: Int { min(contextTokens == 0 ? (currentModelInfo?.contextWindow ?? 8192) : contextTokens,
                                currentModelInfo?.contextWindow ?? 2_097_152) }
    var outputLimit: Int { min(replyTokens, currentModelInfo?.maxOutputTokens ?? replyTokens) }

    func validateModel() throws {
        _ = try CompanionService.endpoint(endpoint, chat: true)
        guard !model.isEmpty, model.count < 200, persona.count < 8000,
              ["auto", "on", "off"].contains(visionMode),
              ["auto", "off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(reasoningEffort),
              contextTokens == 0 || (1024...2_097_152).contains(contextTokens),
              (16...32_768).contains(replyTokens), contextLimit > outputLimit + 128 else {
            throw PetError("请检查模型、上下文和回复上限。")
        }
        if let levels = currentModelInfo?.reasoningLevels, !["auto", "off"].contains(reasoningEffort), !levels.contains(reasoningEffort) {
            throw PetError("该模型未声明支持所选思考程度。")
        }
        if let maximum = currentModelInfo?.contextWindow, contextTokens > maximum { throw PetError("上下文超过模型上限 \(maximum)。") }
        if let maximum = currentModelInfo?.maxOutputTokens, replyTokens > maximum { throw PetError("回复上限超过模型上限 \(maximum)。") }
    }

    func requestBody(messages: [ChatMessage], stream: Bool = true, output: Int? = nil) throws -> [String: Any] {
        var body = try modelOptions(stream: stream, output: output)
        let reserve = min(output ?? outputLimit, outputLimit)
        var context = messages.filter { ["user", "assistant"].contains($0.role) && !$0.content.isEmpty }
        while context.first?.role == "assistant" { context.removeFirst() }
        // No provider tokenizer is bundled. UTF-8 bytes conservatively bound
        // text tokens; trim complete old turns and always retain the new query.
        func cost() -> Int { persona.utf8.count + 32 + context.reduce(0) { $0 + $1.content.utf8.count + 16 } }
        while cost() + reserve > contextLimit && context.count > 1 {
            context.removeFirst(); while context.first?.role == "assistant" { context.removeFirst() }
        }
        guard cost() + reserve <= contextLimit else { throw PetError("本次消息超过上下文预算，请缩短内容或增大上下文。") }
        body["messages"] = [["role": "system", "content": persona]] + context.map { ["role": $0.role, "content": $0.content] }
        return body
    }
    func modelOptions(stream: Bool = true, output: Int? = nil) throws -> [String: Any] {
        try validateModel()
        let reserve = min(output ?? outputLimit, outputLimit)
        var body: [String: Any] = ["model": model, "stream": stream, "max_tokens": reserve]
        let deepSeek = try CompanionService.endpoint(endpoint).host == "api.deepseek.com"
        if deepSeek {
            let thinking = !["auto", "off"].contains(reasoningEffort)
            body["thinking"] = ["type": thinking ? "enabled" : "disabled"]
            if thinking { body["reasoning_effort"] = reasoningEffort }
        } else if reasoningEffort == "off" {
            if currentModelInfo?.reasoningLevels != [] { body["reasoning_effort"] = "none" }
        } else if reasoningEffort != "auto" { body["reasoning_effort"] = reasoningEffort }
        return body
    }
}
