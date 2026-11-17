import AppKit

@MainActor final class AgentSkillCreationLiveBudget {
    static let maximum = 20
    private struct Attempt: Codable { var id = UUID().uuidString; var created = Date() }
    private struct Ledger: Codable { var version = 1, maximum = 20; var configuration: String; var attempts: [Attempt] = [] }
    private let files: AgentFiles, file: URL, authorization: URL, authorizationSignature: String, configuration: String
    private var ledger: Ledger, signature = "missing"
    var used: Int { ledger.attempts.count }
    init(output: URL, preferences: PetPreferences) throws {
        files = try AgentFiles(workspace: output.path)
        file = try files.literalURL("skill-creation-request-ledger.json"); authorization = try files.literalURL("skill-creation-authorization.json")
        guard try files.resolve(authorization.path) == authorization else { throw PetError("Skill 创建验收授权不能使用链接") }
        let data = try files.readData(authorization, maximum: 16_384)
        authorizationSignature = try files.entryMetadata(authorization).signature
        let binary = AgentFiles.hash(try Data(contentsOf: Bundle.main.executableURL!)), inputs = try files.readData(files.literalURL("input-hashes.json"), maximum: 16_384)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any], auth["scope"] as? String == "skill-creation",
              auth["maximumRequests"] as? Int == Self.maximum, auth["contextLimit"] as? Int == 8192, auth["replyLimit"] as? Int == 512, auth["model"] as? String == "deepseek-flash",
              auth["candidateHash"] as? String == binary, auth["inputsHash"] as? String == AgentFiles.hash(inputs),
              (auth["directory"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == output.resolvingSymlinksInPath(),
              preferences.contextLimit == 8192, preferences.outputLimit == 512, preferences.model == "deepseek-flash" else { throw PetError("缺少本轮 Skill 创建最多20次的独立授权，或候选、输入、deepseek-flash、8192／512配置已变化") }
        configuration = Self.fingerprint(preferences) + ":" + binary + ":" + AgentFiles.hash(inputs)
        if FileManager.default.fileExists(atPath: file.path) {
            signature = try files.entryMetadata(file).signature; ledger = try JSONDecoder().decode(Ledger.self, from: files.readData(file, maximum: 65_536))
            guard ledger.version == 1, ledger.maximum == Self.maximum, ledger.configuration == configuration, ledger.attempts.count <= Self.maximum,
                  Set(ledger.attempts.map(\.id)).count == ledger.attempts.count, try files.entryMetadata(file).signature == signature else { throw PetError("Skill 创建请求账本已变化，保留原记录") }
        } else {
            guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("skill-creation-live-fixtures.json").path) else { throw PetError("已有 Skill 创建验收任务，不能清空请求账本") }
            ledger = Ledger(configuration: configuration); try save(ledger)
        }
    }
    private static func fingerprint(_ p: PetPreferences) -> String { AgentFiles.hash(Data([p.endpoint, p.model, String(p.contextLimit), String(p.outputLimit)].joined(separator: "\n").utf8)) }
    private func save(_ next: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.writeData(encoder.encode(next), to: file, permissions: 0o600, expectedTarget: signature)
        signature = try files.entryMetadata(file).signature; ledger = next
    }
    func request(preferences: PetPreferences) throws {
        guard configuration.hasPrefix(Self.fingerprint(preferences) + ":"), used < Self.maximum,
              try files.entryMetadata(authorization).signature == authorizationSignature else { throw PetError("Skill 创建真实请求已达20次，或授权／配置已变化；保留任务和账本") }
        var next = ledger; next.attempts.append(Attempt()); try save(next)
    }
}

@MainActor extension AppDelegate {
    func prepareSkillCreationLiveUI(_ output: URL) throws -> AgentSkillCreationLiveBudget {
        guard Set(CommandLine.arguments.filter { $0.hasPrefix("--") }) == ["--check", "--skill-creation-live-ui", "--live-agent"],
              output.lastPathComponent.hasPrefix("bluefatfish-skill-creation-live-"), usesAgent,
              let tasks = agentStore, let runtime = agentRuntime,
              tasks.hooks.sharedHome == output.appendingPathComponent("shared-home"), !automationNotifications.allowsSystemDelivery else { throw PetError("真实 Skill 创建需独立目录、独立额度和实际工作台，不混用原生样例") }
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        var preferences = PreferencesStore(directory: production).preferences
        preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; preferences.persona = ""
        let budget = try AgentSkillCreationLiveBudget(output: output, preferences: preferences)
        let files = try AgentFiles(workspace: output.path), inputData = try files.readData(files.literalURL("input-hashes.json"), maximum: 16_384)
        let hashes = try JSONDecoder().decode([String: String].self, from: inputData), inputsHash = AgentFiles.hash(inputData)
        guard Set(hashes.keys) == ["project/README.md", "skill-creation-intent.json"] else { throw PetError("Skill 创建公开输入名单无效") }
        for (name, hash) in hashes {
            let url = try files.literalURL(name)
            guard try files.resolve(name) == url, try AgentFiles.hash(files.readData(url, maximum: 100_000)) == hash else { throw PetError("Skill 创建公开输入已变化") }
        }
        let intent = try JSONDecoder().decode([String: String].self, from: files.readData(files.literalURL("skill-creation-intent.json"), maximum: 16_384))
        guard Set(intent.keys) == ["scope", "projectPrompt", "globalPrompt", "usePrompt"], intent["scope"] == "skill-creation", intent.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 3000 }) else { throw PetError("Skill 创建验收要求不匹配") }
        let project = try files.resolve("project"), manifest = output.appendingPathComponent("skill-creation-live-fixtures.json"), ids: [String: String]
        guard project == output.appendingPathComponent("project").standardizedFileURL else { throw PetError("Skill 创建项目不能使用链接") }
        if FileManager.default.fileExists(atPath: manifest.path) {
            ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            guard ids["inputHashes"] == inputsHash,
                  let source = ids["source"], let global = ids["global"], tasks.task(source)?.workspace == project.path,
                  tasks.task(global)?.workspace == nil, tasks.task(global)?.organizationMode == .general else { throw PetError("原 Skill 创建真实任务不可用，保留记录") }
        } else {
            guard budget.used == 0, tasks.tasks.count == 1, tasks.tasks.compactMap({ tasks.task($0.id) }).allSatisfy({ $0.kind == "companion" && $0.messages.isEmpty }) else { throw PetError("本目录已有任务，不重放或替换 Skill 创建验收") }
            let source = tasks.create(title: "Skill 创建公开项目来源", workspace: project.path, mode: .ask)
            let global = tasks.create(title: "No-workspace Skill creation source", mode: .ask, workMode: .general)
            for id in [source, global] { tasks.update(id) { $0.permission = .review; $0.toolGroups = ["files", "extensions"]; $0.draft = id == source ? "保留公开来源任务草稿 🧭" : "Keep the public source draft 🧭" } }
            ids = ["source": source, "global": global, "inputHashes": inputsHash]
            try files.writeData(JSONEncoder().encode(ids), to: manifest, permissions: 0o600, expectedTarget: "missing")
        }
        store.preferences = preferences; try store.savePreferences()
        runtime.modelRequestCheck = { [weak self] in
            let executing = tasks.tasks.filter { runtime.isExecuting($0.id) }
            guard let self, executing.count == 1, let task = executing.first,
                  task.workspaceScope == nil, task.agent == nil, task.team == nil, task.automation == nil,
                  (task.workspace == project.path && task.organizationMode == .coding || task.workspace == nil && task.organizationMode == .general) else { throw PetError("请求不属于本轮公开 Skill 创建范围") }
            if task.skillEvolutionJob?.creation != nil {
                _ = try AgentSkillDrafts.job(task, store: tasks)
                guard task.mode == .plan || task.skillEvolutionJob?.approvedPlan != nil else { throw PetError("请在实际窗口确认当前 Skill 方案") }
            } else {
                let references = task.messages.last(where: \.isHumanInput)?.extensionReferences ?? []
                guard [ids["source"], ids["global"]].contains(task.id), task.mode == .ask, task.permission == .review,
                      Set(task.toolGroups ?? []) == ["files", "extensions"], references.count == 1, let reference = references.first,
                      tasks.tasks.compactMap({ tasks.task($0.id) }).contains(where: { $0.skillEvolutionJob?.creation != nil && $0.skillDraft?.savedAt != nil && $0.skillDraft?.savedID == reference.id && $0.skillDraft?.savedVersion == reference.sha256 }) else { throw PetError("实际使用只允许在原公开任务中载入本轮已保存的 Skill") }
            }
            for (name, hash) in hashes { guard try AgentFiles.hash(files.readData(files.literalURL(name), maximum: 100_000)) == hash else { throw PetError("公开验收输入已变化，保留任务与账本") } }
            try budget.request(preferences: self.store.preferences)
        }
        control.showAgentTask(ids["source"]!); control.show(tab: "chat"); return budget
    }
}
