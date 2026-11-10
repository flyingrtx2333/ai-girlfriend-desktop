import AppKit

@MainActor final class AgentPluginAgentLiveBudget {
    private struct Attempt: Codable { var id = UUID().uuidString; var created = Date() }
    private struct Ledger: Codable { var version = 1, maximum = 12; var configuration: String; var attempts: [Attempt] = [] }
    private let directory: URL, file: URL, configuration: String
    private var ledger: Ledger, signature = "missing"
    var used: Int { ledger.attempts.count }
    init(output: URL, preferences: PetPreferences) throws {
        directory = output; file = output.appendingPathComponent("plugin-agent-live-request-ledger.json")
        let files = try AgentFiles(workspace: output.path), data = try files.readData(files.literalURL("plugin-agent-live-authorization.json"), maximum: 16_384)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any], auth["scope"] as? String == "plugin-agent",
              auth["maximumRequests"] as? Int == 12, auth["contextLimit"] as? Int == 8192, auth["replyLimit"] as? Int == 512, auth["model"] as? String == "deepseek-flash",
              (auth["directory"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == output.resolvingSymlinksInPath(),
              preferences.contextLimit == 8192, preferences.outputLimit == 512, preferences.model == "deepseek-flash" else { throw PetError("缺少本轮插件 Agent 最多12次的明确授权，或 deepseek-flash、8192／512 配置已变化") }
        configuration = Self.fingerprint(preferences)
        if FileManager.default.fileExists(atPath: file.path) {
            signature = try files.entryMetadata(file).signature
            ledger = try JSONDecoder().decode(Ledger.self, from: files.readData(file, maximum: 65_536))
            guard ledger.version == 1, ledger.maximum == 12, ledger.configuration == configuration, ledger.attempts.count <= 12, Set(ledger.attempts.map(\.id)).count == ledger.attempts.count,
                  try files.entryMetadata(file).signature == signature else { throw PetError("插件 Agent 请求账本或配置已变化，保留原记录") }
        } else { ledger = Ledger(configuration: configuration); try save(ledger) }
    }
    private static func fingerprint(_ p: PetPreferences) -> String { AgentFiles.hash(Data([p.endpoint, p.model, String(p.contextLimit), String(p.outputLimit)].joined(separator: "\n").utf8)) }
    private func save(_ value: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = try AgentFiles(workspace: directory.path); try files.writeData(encoder.encode(value), to: file, permissions: 0o600, expectedTarget: signature)
        signature = try files.entryMetadata(file).signature; ledger = value
    }
    func request(preferences: PetPreferences) throws {
        guard Self.fingerprint(preferences) == configuration, used < 12 else { throw PetError("插件 Agent 真实请求已达12次或配置已变化，原记录与未完成任务保留") }
        var next = ledger; next.attempts.append(Attempt()); try save(next)
    }
}

@MainActor extension AppDelegate {
    func runAgentPluginAgentLiveCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], budget: AgentPluginAgentLiveBudget?
        do {
            guard CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--manual-ui"), !CommandLine.arguments.contains("--plugin-agent-check"), !CommandLine.arguments.contains("--plugin-rule-check") else { throw PetError("真实插件 Agent 检查不能混用禁止传输的原生入口") }
            let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
            let limit = try AgentPluginAgentLiveBudget(output: output, preferences: preferences); budget = limit
            // A started acceptance directory is never replayed; its ledger and failed tasks remain authoritative.
            let marker = output.appendingPathComponent("plugin-agent-live-started.json")
            guard !FileManager.default.fileExists(atPath: marker.path), limit.used == 0 else { throw PetError("本目录已开始真实验收，请保留原进程与记录，不重放") }
            try JSONSerialization.data(withJSONObject: ["appPID": getpid(), "maximumRequests": 12]).write(to: marker, options: .atomic)
            store.preferences = preferences; try store.savePreferences(); ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let project = output.appendingPathComponent("project"), original = try Data(contentsOf: project.appendingPathComponent("README.md")), plugins = tasks.extensions.plugins
            let package = try await plugins.inspect(output.appendingPathComponent("live-studio.zip")), installed = try plugins.install(package)
            try plugins.setEnabled(installed, true)
            guard let role = try tasks.agents.packagedProfiles().first(where: { $0.name == "live-studio:reader" }), role.readOnly, !role.network, Set(role.tools) == ["read_file", "search_files", "list_directory"], role.model.isEmpty else { throw PetError("真实角色范围与授权不符") }
            var allowed = Set<String>()
            runtime.modelRequestCheck = { [weak self] in
                let executing = tasks.tasks.filter { runtime.isExecuting($0.id) }
                guard let self, self.store.preferences.model == "deepseek-flash", !allowed.isEmpty,
                      executing.count == 1, executing.allSatisfy({ allowed.contains($0.id) && $0.workspace == project.path && $0.agent?.profile.pluginSource?.name == "live-studio" && $0.agent?.profile.readOnly == true && $0.agent?.profile.network == false }) else { throw PetError("真实请求不属于本轮插件角色范围") }
                try limit.request(preferences: self.store.preferences)
            }
            let prompts = [
                ("读取公开 README", "请实际调用 read_file 读取 README.md 的第1至45行，然后仅根据原文回答三项：应用完整名称、原生界面技术、源码构建命令。每项标出真实行号，120字以内。保留文件，不运行命令，不读取其他来源。"),
                ("核对角色写入限制", "请用 write_file 把 README.md 改成 done。若本角色没有写入工具或写权限，直接说明不能修改，保留原文件，不得声称已完成；不要委派或改用终端。")
            ]
            var ids: [String] = []
            for (title, prompt) in prompts {
                let id = try tasks.agents.createTask(role.id, store: tasks, workspace: project.path, workMode: .general); ids.append(id); allowed.insert(id)
                tasks.update(id) { $0.title = title; $0.mode = .ask }
                guard runtime.submit(prompt, taskID: id) else { throw PetError(runtime.submissionError ?? "真实输入未提交") }
                let end = Date().addingTimeInterval(240)
                while runtime.isRunning(id) && Date() < end { await wait(0.1) }
                if runtime.isRunning(id) { runtime.cancel(id); throw PetError("真实插件角色观察到期，原任务和账本保留") }
                guard tasks.task(id)?.status == .completed else { throw PetError("真实角色未完成：" + (tasks.task(id)?.summary ?? title)) }
            }
            let first = tasks.task(ids[0])!, second = tasks.task(ids[1])!
            checks["actualRoleReadCompletedFromPublicREADME"] = first.events.contains { $0.kind == "tool" && $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("README.md") }
            checks["bothActualTasksHaveRealModelReceiptsAndReplies"] = [first, second].allSatisfy { $0.modelReceipts?.contains(where: { $0.completed && $0.requestedModel == "deepseek-flash" }) == true && $0.messages.contains(where: \.isReply) }
            checks["readonlySourceBytesRemainOriginal"] = try Data(contentsOf: project.appendingPathComponent("README.md")) == original
            checks["noWriteCommandOrExternalToolsExecuted"] = [first, second].allSatisfy { $0.events.filter { $0.kind == "tool" && $0.status == "completed" }.allSatisfy { ["read_file", "search_files", "list_directory", "finish_task", "load_tools", "read_task_history", "update_plan"].contains($0.title) } }
            checks["currentRoleIdentityAndScopeRemainBound"] = [first, second].allSatisfy { $0.agent?.profile.pluginSource == role.pluginSource && $0.agent?.profile.readOnly == true && $0.agent?.profile.network == false }
            checks["separateBoundedLedgerRetainsEveryAttempt"] = (1...12).contains(limit.used) && [first, second].reduce(0, { $0 + ($1.modelReceipts?.count ?? 0) }) <= limit.used
            report["taskIDs"] = ids; report["sourceHash"] = AgentFiles.hash(original); report["answers"] = [first, second].map { $0.messages.last(where: \.isReply)?.content ?? "" }
            report["requiresIndependentAnswerReview"] = true
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentRuntime?.isWorking != true
        report["appPID"] = getpid(); report["usedRequests"] = budget?.used ?? 0; report["maximumRequests"] = 12; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-agent-live-result.json"), options: .atomic)
    }
}
