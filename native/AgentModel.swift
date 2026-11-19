import Foundation

@MainActor struct AgentModelRequestHooks {
    let store: AgentStore
    let taskID: String
    let turnID: String

    func fire(_ event: AgentHookEvent, attempt: String, origin: AgentTaskRecord, model: String, key: String, outcome: [String: Any] = [:]) async {
        var fields = outcome
        fields["session_id"] = origin.hookSession ?? origin.id
        fields["turn_id"] = turnID
        fields["model"] = model
        if let agent = origin.agent {
            fields["agent_id"] = origin.id
            fields["agent_type"] = agent.profile.name
        }
        await store.hooks.observeModelRequest(event, attempt: attempt, origin: origin, store: store, fields: fields, secret: key)
    }
}

enum AgentModel {
    @MainActor static func requestBody(preferences: PetPreferences, system: String, messages: [AgentMessage], tools: [[String: Any]], requiredTool: String? = nil, visuals: [String: [AgentVisualInput]] = [:]) throws -> [String: Any] {
        let snapshot = try AgentContext.snapshot(preferences: preferences, system: system, skills: "", messages: messages, tools: tools, loadedSkills: 0)
        guard snapshot.estimatedTokens + preferences.outputLimit <= preferences.contextLimit else { throw PetError("Agent请求超过当前上下文预算，请整理历史或提高上限") }
        var body = try preferences.modelOptions(stream: true)
        body["messages"] = [["role": "system", "content": system]] + AgentAttachmentVisuals.wire(messages: messages, inputs: visuals)
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto"; body["parallel_tool_calls"] = false }
        if let requiredTool {
            guard tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == requiredTool }) else { throw PetError("指定步骤的工具未载入") }
            // DeepSeek thinking mode rejects named tool choices; preserve the selected mode.
            let deepSeek = try CompanionService.endpoint(preferences.endpoint).host == "api.deepseek.com"
            if !deepSeek || (body["thinking"] as? [String: String])?["type"] == "disabled" { body["tool_choice"] = ["type": "function", "function": ["name": requiredTool]] }
        }
        body["stream_options"] = ["include_usage": true]
        return body
    }
    @MainActor static func turn(preferences: PetPreferences, key: String, system: String, messages: [AgentMessage], tools: [[String: Any]], requiredTool: String? = nil, visuals: [String: [AgentVisualInput]] = [:], allowPartialContent: Bool = false,
                                purpose: String = "conversation", messageID: String? = nil, requestHooks: AgentModelRequestHooks? = nil, onReceipt: ((AgentModelReceipt) -> Void)? = nil,
                                onText: @escaping (String) -> Void) async throws -> AgentTurn {
        let url = try CompanionService.endpoint(preferences.endpoint, chat: true)
        guard !key.isEmpty || CompanionService.isLocal(url.host ?? "") else { throw PetError("请先填写对话 Token") }
        let body = try requestBody(preferences: preferences, system: system, messages: messages, tools: tools, requiredTool: requiredTool, visuals: visuals)
        let request = try CompanionService.request(url: url, key: key, body: body)
        try Task.checkCancellation()
        let model = preferences.model, attempt = UUID().uuidString
        let origin = requestHooks.flatMap { $0.store.task($0.taskID) }
        if let requestHooks, let origin { await requestHooks.fire(.preModelRequest, attempt: attempt, origin: origin, model: model, key: key) }
        var tokens: [String: Int] = [:]
        func finish(_ status: String, error: Error? = nil) async {
            guard let requestHooks, let origin else { return }
            let message = error?.localizedDescription
            let redacted = key.isEmpty ? message : message?.replacingOccurrences(of: key, with: "[凭据已隐藏]")
            let outcome: [String: Any] = ["status": status, "error": redacted.map { String($0.prefix(1000)) } as Any? ?? NSNull(),
                                          "token_usage": tokens.isEmpty ? NSNull() as Any : tokens]
            if Task.isCancelled || status == "cancelled" {
                // Finishing an audit must not delay releasing the cancelled task.
                Task { @MainActor in await requestHooks.fire(.postModelRequest, attempt: attempt, origin: origin, model: model, key: key, outcome: outcome) }
            } else {
                await requestHooks.fire(.postModelRequest, attempt: attempt, origin: origin, model: model, key: key, outcome: outcome)
            }
        }
        do {
            try Task.checkCancellation()
            let result = try await receive(request, model: model, key: key, allowPartialContent: allowPartialContent,
                                           purpose: purpose, messageID: messageID, tokens: &tokens, onReceipt: onReceipt, onText: onText)
            await finish("completed")
            return result
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            await finish(cancelled ? "cancelled" : "failed", error: cancelled ? nil : error)
            throw error
        }
    }

    @MainActor private static func receive(_ request: URLRequest, model: String, key: String, allowPartialContent: Bool,
                                           purpose: String, messageID: String?, tokens: inout [String: Int],
                                           onReceipt: ((AgentModelReceipt) -> Void)?, onText: (String) -> Void) async throws -> AgentTurn {
        let started = Date()
        let (bytes, response) = try await CompanionService.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PetError("模型响应无法读取") }
        guard (200...299).contains(http.statusCode) else {
            var data = Data(); for try await byte in bytes { data.append(byte); if data.count >= 8192 { break } }
            throw CompanionService.serverError(data, status: http.statusCode, key: key)
        }
        var result = AgentTurn(), calls: [Int: AgentToolCall] = [:]
        var completed = false
        defer {
            onReceipt?(AgentModelReceipt(purpose: purpose, requestedModel: model, returnedModel: result.returnedModel,
                inputTokens: result.inputTokensReported ? result.inputTokens : nil, outputTokens: result.outputTokensReported ? result.outputTokens : nil,
                finishReason: result.finishReason.isEmpty ? "interrupted" : result.finishReason,
                duration: Date().timeIntervalSince(started), completed: completed, messageID: messageID))
        }
        func usage(_ object: [String: Any]) {
            if let model = object["model"] as? String, AgentTaskModels.validID(model) { result.returnedModel = model }
            if let value = object["usage"] as? [String: Any] {
                if let count = value["prompt_tokens"] as? Int, count >= 0 { result.inputTokens = count; result.inputTokensReported = true }
                if let count = value["completion_tokens"] as? Int, count >= 0 { result.outputTokens = count; result.outputTokensReported = true }
                let input = value["prompt_tokens_details"] as? [String: Any], output = value["completion_tokens_details"] as? [String: Any]
                let reported: [(String, Any?)] = [("input_tokens", value["prompt_tokens"]), ("output_tokens", value["completion_tokens"]),
                    ("total_tokens", value["total_tokens"]), ("cached_input_tokens", input?["cached_tokens"] ?? value["prompt_cache_hit_tokens"]),
                    ("cache_write_input_tokens", value["cache_write_input_tokens"]), ("reasoning_output_tokens", output?["reasoning_tokens"])]
                for (field, raw) in reported {
                    if let raw, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), let count = raw as? Int, count >= 0 { tokens[field] = count }
                }
            }
        }
        func consume(_ object: [String: Any], streamed: Bool) throws {
            if object["error"] != nil { throw CompanionService.serverError(try JSONSerialization.data(withJSONObject: object), status: 200, key: key) }
            usage(object)
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return }
            result.finishReason = choice["finish_reason"] as? String ?? result.finishReason
            let delta = choice[streamed ? "delta" : "message"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String { result.content += text; onText(text) }
            if let reasoning = delta["reasoning_content"] as? String { result.reasoning += reasoning }
            for (offset, value) in (delta["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let index = value["index"] as? Int ?? offset, function = value["function"] as? [String: Any] ?? [:]
                var call = calls[index] ?? AgentToolCall(id: "", name: "", arguments: "")
                call.id += value["id"] as? String ?? ""; call.name += function["name"] as? String ?? ""; call.arguments += function["arguments"] as? String ?? ""
                guard call.arguments.utf8.count <= 1_000_000 else { throw PetError("工具参数过长") }; calls[index] = call
            }
            guard result.content.utf8.count + result.reasoning.utf8.count <= 500_000 else { throw PetError("模型响应过长") }
        }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
            var data = Data(); for try await byte in bytes { data.append(byte); if data.count > 2_000_000 { throw PetError("模型响应过长") } }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("模型响应格式错误") }
            try consume(object, streamed: false)
        } else {
            for try await line in bytes.lines {
                try Task.checkCancellation(); guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard payload.utf8.count <= 1_100_000 else { throw PetError("模型响应格式异常") }
                guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }
                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { try consume(object, streamed: true) }
            }
        }
        result.calls = calls.keys.sorted().compactMap { calls[$0] }
        guard !result.finishReason.isEmpty else { throw PetError("模型响应中断，请继续任务") }
        guard result.finishReason != "length" || allowPartialContent else { throw PetError("本轮回复预算已用尽，可提高回复上限后继续任务") }
        guard result.calls.count <= 32, Set(result.calls.map(\.id)).count == result.calls.count,
              result.calls.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { throw PetError("模型返回的工具调用无效") }
        guard !result.content.isEmpty || !result.calls.isEmpty || allowPartialContent && result.finishReason == "length" else { throw PetError(result.finishReason == "length" ? "模型预算已用尽，请提高回复上限" : "模型未返回文字或工具调用") }
        completed = true
        return result
    }
}
