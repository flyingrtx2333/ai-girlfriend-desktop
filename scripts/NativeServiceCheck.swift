import Foundation

@main struct NativeServiceCheck {
    @MainActor static func main() async throws {
        let base = CommandLine.arguments[1], output = URL(fileURLWithPath: CommandLine.arguments[2])
        var p = PetPreferences(), checks: [String: Bool] = [:], chunks: [String] = []
        let context = [ChatMessage(role: "user", content: "你好，小鲸。")]
        let token = "fixture-0123456789-abcdefghijklmnopqrstuvwxyz"
        checks["savedTokenIsPartial"] = TokenPreview.mask(token) == String(token.prefix(12)) + " … " + String(token.suffix(12))
            && !TokenPreview.mask(token).contains(token) && !TokenPreview.mask("short-token").contains("short-token")
        var settings = p; settings.endpoint = "https://api.deepseek.com"; settings.reasoningEffort = "high"
        var body = try settings.requestBody(messages: context)
        checks["deepSeekThinkingApplied"] = (body["thinking"] as? [String: String])?["type"] == "enabled" && body["reasoning_effort"] as? String == "high"
        settings.reasoningEffort = "auto"; body = try settings.requestBody(messages: context)
        checks["deepSeekDefaultKeepsFastMode"] = (body["thinking"] as? [String: String])?["type"] == "disabled"
        settings.contextTokens = 1024; settings.replyTokens = 128; settings.persona = "小鲸"
        let turns = [ChatMessage(role: "user", content: String(repeating: "旧", count: 500)), ChatMessage(role: "assistant", content: "旧回复"), ChatMessage(role: "user", content: "保留本次问题")]
        body = try settings.requestBody(messages: turns)
        let retained = body["messages"] as? [[String: String]] ?? []
        checks["contextBudgetKeepsWholeRecentTurn"] = retained.count == 2 && retained.last?["content"] == "保留本次问题"
        do { _ = try settings.requestBody(messages: [ChatMessage(role: "user", content: String(repeating: "长", count: 500))]); checks["oversizedQueryRejected"] = false }
        catch { checks["oversizedQueryRejected"] = true }
        let catalog = try await CompanionService.models(endpoint: base + "/discovery/chat/completions", key: "fixture-key")
        checks["capabilityDiscovery"] = catalog.first?.vision == true && catalog.first?.contextWindow == 32768
            && catalog.first?.reasoningLevels == ["low", "high", "max"] && catalog.last?.vision == nil && catalog.last?.reasoningLevels == nil
        settings = p; settings.endpoint = base + "/discovery"; settings.model = "fixture-model"; settings.modelInfo = catalog.first
        settings.reasoningEffort = "high"; settings.replyTokens = 2048; settings.contextTokens = 16384
        body = try settings.requestBody(messages: context)
        checks["selectedRequestOptionsApplied"] = body["max_tokens"] as? Int == 2048 && body["reasoning_effort"] as? String == "high" && settings.visionSupported == true
        let probe = try await CompanionService.probe(preferences: settings, key: "fixture-key")
        checks["connectionProbeRequiresReply"] = probe.reply == "OK" && !probe.thinkingBudgetReached
        settings.reasoningEffort = "medium"
        do { try settings.validateModel(); checks["unsupportedEffortRejected"] = false } catch { checks["unsupportedEffortRejected"] = true }
        settings.reasoningEffort = "low"; settings.model = "different-model"
        checks["capabilitiesScopedToModel"] = settings.currentModelInfo == nil && settings.visionSupported == nil
        p.endpoint = base + "/stream"
        let text = try await CompanionService.stream(preferences: p, key: "fixture-key", messages: context) { chunks.append($0) }
        checks["fragmentedUTF8Stream"] = text == "你好，我在呢。" && chunks.count == 3
        checks["endpointPath"] = try CompanionService.endpoint(base + "/v1", chat: true).path == "/v1/chat/completions"
        p.endpoint = base + "/json"
        checks["jsonFallback"] = try await CompanionService.stream(preferences: p, key: "", messages: context) { _ in } == "完整回复"
        p.endpoint = base + "/error"
        do {
            _ = try await CompanionService.stream(preferences: p, key: "fixture-key", messages: context) { _ in }
            checks["errorRedactsKey"] = false
        } catch { checks["errorRedactsKey"] = !error.localizedDescription.contains("fixture-key") && error.localizedDescription.contains("[已隐藏]") }
        p.endpoint = base + "/auth"
        do { _ = try await CompanionService.probe(preferences: p, key: "fixture-key"); checks["authErrorIsConcise"] = false }
        catch { checks["authErrorIsConcise"] = error.localizedDescription == "鉴权失败，请检查 Token 与接口。" }
        p.endpoint = base + "/slow"
        let slow = p
        let task = Task { @MainActor in try await CompanionService.stream(preferences: slow, key: "", messages: context) { _ in } }
        try await Task.sleep(nanoseconds: 120_000_000); task.cancel()
        do { _ = try await task.value; checks["streamCancellation"] = false }
        catch { checks["streamCancellation"] = error is CancellationError || (error as? URLError)?.code == .cancelled }
        p.voiceEndpoint = base + "/speech"
        let audio = try await CompanionService.speech(text: "我在呢。", preferences: p, key: "fixture-key")
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        checks["miniMaxHexDecoding"] = audio == expected
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks,
            "scope": "Local HTTP protocol fixture, not a live AI or TTS quality test. No provider calls or keychain writes."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        if !checks.values.allSatisfy({ $0 }) { exit(1) }
    }
}
