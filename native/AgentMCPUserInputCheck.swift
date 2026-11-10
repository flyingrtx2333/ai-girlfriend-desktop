import AppKit

@MainActor final class AgentMCPInputCheck {
    private let output: URL, tasks: AgentStore, workspace: URL
    let taskID: String, otherID: String, sourceTitle: String, sourceHash: String
    private let stdio: AgentMCPServer, http: AgentMCPServer
    private let url: String
    private var serial = 0, uiJob: Task<Void, Never>?
    static func write(_ data: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    init(output: URL, tasks: AgentStore, runtime: AgentRuntime) throws {
        let workspace = output.appendingPathComponent("workspace")
        self.output = output; self.tasks = tasks; self.workspace = workspace
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("mcp-input-fixture.json"))) as? [String: Any] ?? [:]
        guard let node = fixture["node"] as? String, let entry = fixture["serverEntry"] as? String, let endpoint = fixture["endpoint"] as? String, let url = fixture["publicURL"] as? String else { throw PetError("缺少已核对的本地 MCP 服务") }
        self.url = url
        let readme = try Data(contentsOf: workspace.appendingPathComponent("README.md"))
        sourceHash = AgentFiles.hash(readme)
        let title = String(decoding: readme, as: UTF8.self).components(separatedBy: "\n").first ?? ""
        sourceTitle = title
        guard !title.isEmpty else { throw PetError("公开 README 缺少标题") }
        func config(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        stdio = try tasks.mcp.save(config(["name": "官方 MCP · 本机", "type": "stdio", "command": node, "args": [entry], "env": [:], "timeoutSeconds": 5]))
        http = try tasks.mcp.save(config(["name": "官方 MCP · HTTP", "type": "http", "url": endpoint, "timeoutSeconds": 5]))
        taskID = tasks.create(title: "公开 README 问询", workspace: workspace.path, mode: .agent)
        otherID = tasks.create(title: "另一项问答", mode: .ask, workMode: .general)
        guard runtime.submit(sourceTitle, taskID: taskID, startImmediately: false) else { throw PetError("公开正文未保存") }
        tasks.update(taskID) { $0.draft = "这份草稿不发送给连接器。" }
        tasks.update(otherID) { $0.draft = "另一项任务的草稿。" }
        tasks.selectedID = taskID
        try Self.write(["taskID": taskID, "otherTaskID": otherID, "sourceHash": sourceHash, "stdioServerID": stdio.id, "httpServerID": http.id], to: output.appendingPathComponent("mcp-input-created.json"))
    }
    func begin(_ name: String = "trigger-elicitation-request", transport: String = "stdio", arguments: [String: Any] = [:]) -> Task<AgentToolResult, Error> {
        Task { @MainActor [self] in
            let server = transport == "http" ? http : stdio, mcp = tasks.mcp
            _ = try await mcp.connect(server.id, revision: server.revision, owner: taskID, workspace: workspace.path)
            guard let token = mcp.token(server.id, owner: taskID) else { throw PetError("未取得实际连接") }
            let listed = try mcp.catalog(server.id, owner: taskID, token: token, offset: 0, query: name)
            guard (listed["tools"] as? [[String: Any]])?.contains(where: { $0["name"] as? String == name }) == true else { throw PetError("官方服务未公布工具：" + name) }
            return try await mcp.call(server.id, owner: taskID, token: token, name: name, arguments: arguments, store: tasks)
        }
    }
    private func question(excluding prior: String? = nil) async throws -> AgentMCPUserInput {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let request = tasks.mcp.userInputs.first(taskID: taskID), request.id != prior { return request }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw PetError("原请求没有收到连接器问询；检查实际工具结果和进程")
    }
    private func raw(_ result: AgentToolResult) throws -> [String: Any] {
        guard let body = result.text.components(separatedBy: "Raw result: ").dropFirst().last,
              let value = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { throw PetError("官方服务未返回实际问询结果：" + String(result.text.prefix(500))) }
        return value
    }
    func run() async throws -> [String: Any] {
        var checks: [String: Bool] = [:], actual: [String: Any] = [:]
        let mcp = tasks.mcp, inputs = mcp.userInputs
        let job = begin(), request = try await question()
        checks["realOfficialFormAndTaskScope"] = request.fields.count == 13 && request.taskID == taskID && inputs.first(taskID: otherID) == nil
        var values = Dictionary(uniqueKeysWithValues: request.fields.compactMap { field in field.initial.map { (field.key, $0) } })
        values["name"] = sourceTitle; values["check"] = false; values["integer"] = 17; values["number"] = 19.5
        values["homepage"] = "https://github.com/flyingrtx2333/ai-girlfriend-desktop"
        values["birthdate"] = "2026-11-11"; values["titledMultipleSelectEnum"] = ["fish-2", "fish-3"]
        do { try inputs.respond(taskID: otherID, id: request.id, action: .accept, values: values); checks["wrongOwnerCannotRespond"] = false }
        catch { checks["wrongOwnerCannotRespond"] = inputs.first(taskID: taskID)?.id == request.id }
        var invalid = values; invalid["integer"] = 101
        do { try inputs.respond(taskID: taskID, id: request.id, action: .accept, values: invalid); checks["invalidIntegerKeepsRequestOpen"] = false }
        catch { checks["invalidIntegerKeepsRequestOpen"] = inputs.first(taskID: taskID)?.id == request.id }
        var missing = values; missing["name"] = nil
        do { try inputs.respond(taskID: taskID, id: request.id, action: .accept, values: missing); checks["requiredFieldCannotBeOmitted"] = false }
        catch { checks["requiredFieldCannotBeOmitted"] = inputs.first(taskID: taskID)?.id == request.id }
        try await Task.sleep(for: .milliseconds(5300))
        checks["userWaitDoesNotConsumeToolTimeout"] = inputs.first(taskID: taskID)?.id == request.id && mcp.connected(stdio.id, owner: taskID)
        try inputs.respond(taskID: taskID, id: request.id, action: .accept, values: values)
        let reply = try raw(try await job.value); actual["accepted"] = reply
        let returned = try JSONSerialization.data(withJSONObject: reply["content"] ?? [:], options: [.sortedKeys])
        let submitted = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        checks["officialServerReturnsTypedContentExactly"] = reply["action"] as? String == "accept" && submitted == returned
        checks["acceptedContentDoesNotEnterTaskHistory"] = tasks.task(taskID)?.events.last(where: { $0.id == request.id })?.detail == "已确认提交表单" && tasks.task(taskID)?.messages.count == 1 && tasks.task(taskID)?.draft == "这份草稿不发送给连接器。"
        let multi = begin("trigger-multi-step-elicitation"), first = try await question()
        try inputs.respond(taskID: taskID, id: first.id, action: .accept, values: ["name": sourceTitle])
        let second = try await question(excluding: first.id)
        checks["secondActualQuestionUsesFirstAnswer"] = second.message.contains(sourceTitle) && second.fields.first?.key == "color"
        try inputs.respond(taskID: taskID, id: second.id, action: .accept, values: ["color": "blue"])
        let multiResult = try await multi.value; actual["multi"] = multiResult.text
        checks["actualMultiStepResult"] = !multiResult.failed && multiResult.text.contains(sourceTitle) && multiResult.text.contains("blue")
        for (action, transport) in [(AgentMCPUserInput.Action.decline, "http"), (.cancel, "stdio")] {
            let work = begin(transport: transport), item = try await question()
            try inputs.respond(taskID: taskID, id: item.id, action: action, values: ["name": "未提交的公开示例"])
            let response = try raw(try await work.value); actual[action.rawValue] = response
            checks["actual-\(transport)-\(action.rawValue)-without-content"] = response["action"] as? String == action.rawValue && response["content"] == nil
        }
        let stale = begin(), staleItem = try await question()
        tasks.update(taskID) { $0.mode = .ask }
        do { try inputs.respond(taskID: taskID, id: staleItem.id, action: .accept, values: values); checks["changedModeCannotTransmit"] = false }
        catch { checks["changedModeCannotTransmit"] = inputs.first(taskID: taskID) == nil }
        let staleResult = try raw(try await stale.value); actual["stale"] = staleResult
        checks["changedModeReturnsNoContent"] = staleResult["action"] as? String == "cancel" && staleResult["content"] == nil
        tasks.update(taskID) { $0.mode = .agent }
        let urlWork = begin("trigger-url-elicitation", arguments: ["url": url, "message": "查看本机公开 README"]), urlItem = try await question()
        checks["actualURLHasHostAndNoFormValues"] = urlItem.url?.absoluteString == url && urlItem.fields.isEmpty && urlItem.urlID != nil
        try inputs.respond(taskID: taskID, id: urlItem.id, action: .decline)
        let urlResult = try raw(try await urlWork.value); actual["urlDecline"] = urlResult
        checks["declinedURLNoNavigationOrContent"] = urlResult["action"] as? String == "decline" && urlResult["content"] == nil
        let prereq = begin("trigger-url-elicitation", arguments: ["url": url, "message": "查看公开 README", "errorPath": true]), prereqItem = try await question()
        checks["realProtocolErrorSurfacesPrerequisite"] = prereqItem.url?.host == "modelcontextprotocol.io"
        try inputs.respond(taskID: taskID, id: prereqItem.id, action: .cancel)
        do { _ = try await prereq.value; checks["prerequisiteCancellationKeepsConnection"] = false }
        catch { checks["prerequisiteCancellationKeepsConnection"] = mcp.connected(stdio.id, owner: taskID) && error.localizedDescription.contains("未完成"); actual["urlPrerequisite"] = error.localizedDescription }
        let closing = begin(), last = try await question(), pid = await mcp.processID(stdio.id, owner: taskID)
        mcp.disconnect(owner: taskID)
        _ = try? await closing.value
        if let pid {
            let end = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0 && Date() < end { try await Task.sleep(for: .milliseconds(40)) }
            checks["originalServerProcessExited"] = kill(pid, 0) != 0; actual["stdioPID"] = pid
        } else { checks["originalServerProcessExited"] = false }
        checks["disconnectClearsRealPendingRequest"] = inputs.first(taskID: taskID) == nil && !mcp.connected(stdio.id, owner: taskID)
        do { try inputs.respond(taskID: taskID, id: last.id, action: .accept, values: values); checks["oldRequestCannotBeReplayed"] = false }
        catch { checks["oldRequestCannotBeReplayed"] = true }
        checks["bothDraftsAndNoNewAssistantOrReceipt"] = tasks.task(taskID)?.draft == "这份草稿不发送给连接器。" && tasks.task(otherID)?.draft == "另一项任务的草稿。" && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty }
        return ["checks": checks, "actual": actual, "expectedAcceptedContent": values, "sourceHash": sourceHash, "success": checks.values.allSatisfy { $0 }]
    }
    func pollUI() {
        guard uiJob == nil, let data = try? Data(contentsOf: output.appendingPathComponent("mcp-input-ui-command.json")),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let next = value["serial"] as? Int, next == serial + 1,
              let operation = value["operation"] as? String, ["form", "http-form", "multi", "url", "url-prerequisite", "disconnect"].contains(operation) else { return }
        serial = next
        if operation == "disconnect" {
            tasks.mcp.disconnect(owner: taskID)
            try? Self.write(["success": true, "appPID": getpid(), "pending": tasks.mcp.userInputs.first(taskID: taskID) != nil], to: output.appendingPathComponent("mcp-input-ui-result-\(next).json"))
            return
        }
        let job: Task<AgentToolResult, Error>
        switch operation {
        case "url", "url-prerequisite": job = begin("trigger-url-elicitation", arguments: ["url": url, "message": "查看本机公开 README", "errorPath": operation == "url-prerequisite"])
        case "multi": job = begin("trigger-multi-step-elicitation")
        default: job = begin(transport: operation == "http-form" ? "http" : "stdio")
        }
        uiJob = Task { @MainActor [self] in
            let result: [String: Any]
            do {
                let reply = try await job.value
                result = ["success": !reply.failed, "appPID": getpid(), "text": reply.text, "raw": (try? raw(reply)) ?? [:]]
            } catch { result = ["success": false, "appPID": getpid(), "error": error.localizedDescription] }
            try? Self.write(result, to: output.appendingPathComponent("mcp-input-ui-result-\(next).json")); uiJob = nil
        }
    }
}

@MainActor extension AppDelegate {
    func runAgentMCPUserInputCheck(_ output: URL) async {
        var requests = 0, report: [String: Any]
        do {
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try AgentMCPInputCheck.write(["appPID": getpid(), "binaryHash": hash], to: output.appendingPathComponent("mcp-input-started.json"))
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("连接器问询验收不调用模型") }
            report = try await AgentMCPInputCheck(output: output, tasks: tasks, runtime: runtime).run()
            report["binaryHash"] = hash; report["success"] = report["success"] as? Bool == true && requests == 0
        } catch { report = ["success": false, "error": error.localizedDescription] }
        agentRuntime?.stopAll(); report["appPID"] = getpid(); report["blockedModelAttempts"] = requests
        try? AgentMCPInputCheck.write(report, to: output.appendingPathComponent("mcp-input-report.json"))
    }
}
