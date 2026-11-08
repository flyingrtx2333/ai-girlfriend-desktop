import Foundation

struct ModelInfo: Codable {
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
