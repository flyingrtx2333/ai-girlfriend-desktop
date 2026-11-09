import AppKit

@MainActor final class AgentAttentionLiveBudget {
    private struct Attempt: Codable { var id = UUID().uuidString; var created = Date() }
    private struct Ledger: Codable { var version = 1; var maximum: Int; var configuration: String; var attempts: [Attempt] = [] }
    private let directory: URL, file: URL
    private var ledger: Ledger, signature = "missing"
    var used: Int { ledger.attempts.count }
    init(output: URL, preferences: PetPreferences) throws {
        directory = output; file = output.appendingPathComponent("attention-live-request-ledger.json")
        let files = try AgentFiles(workspace: output.path)
        let data = try files.readData(files.literalURL("attention-live-authorization.json"), maximum: 16_384)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any], auth["scope"] as? String == "attention-plan",
              auth["maximumRequests"] as? Int == 8, auth["contextLimit"] as? Int == 8192, auth["replyLimit"] as? Int == 512,
              (auth["directory"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == output.resolvingSymlinksInPath(),
              preferences.contextLimit == 8192, preferences.outputLimit == 512 else { throw PetError("缺少本轮收件箱最多8次的明确授权，或8192／512配置已变化") }
        let config = AgentFiles.hash(Data([preferences.endpoint, preferences.model, "8192", "512"].joined(separator: "\n").utf8))
        if FileManager.default.fileExists(atPath: file.path) {
            signature = try files.entryMetadata(file).signature
            ledger = try JSONDecoder().decode(Ledger.self, from: files.readData(file, maximum: 65_536))
            guard ledger.version == 1, ledger.maximum == 8, ledger.configuration == config, ledger.attempts.count <= 8, Set(ledger.attempts.map(\.id)).count == ledger.attempts.count,
                  try files.entryMetadata(file).signature == signature else { throw PetError("真实请求账本或配置已变化，保留原记录") }
        } else { ledger = Ledger(maximum: 8, configuration: config); try save(ledger) }
    }
    private func save(_ value: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = try AgentFiles(workspace: directory.path); try files.writeData(encoder.encode(value), to: file, permissions: 0o600, expectedTarget: signature)
        signature = try files.entryMetadata(file).signature; ledger = value
    }
    func request() throws {
        guard used < ledger.maximum else { throw PetError("收件箱真实请求已达8次，原记录与未完成任务保留") }
        var next = ledger; next.attempts.append(Attempt()); try save(next)
    }
}

@MainActor extension AppDelegate {
    func prepareAttentionLiveUI(_ output: URL) throws -> AgentAttentionLiveBudget {
        guard !CommandLine.arguments.contains("--manual-ui"), !CommandLine.arguments.contains("--attention-fixtures"), !CommandLine.arguments.contains("--task-window-fixtures"), let tasks = agentStore else { throw PetError("真实收件箱检查不能混用禁止传输的原生检查") }
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        var preferences = PreferencesStore(directory: production).preferences
        preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
        let budget = try AgentAttentionLiveBudget(output: output, preferences: preferences)
        store.preferences = preferences; try store.savePreferences()
        let manifest = output.appendingPathComponent("attention-live-fixtures.json"), id: String
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any], let existing = saved["taskID"] as? String, tasks.task(existing) != nil else { throw PetError("原真实计划任务不可用，未覆盖记录") }; id = existing
        } else {
            let project = output.appendingPathComponent("project").resolvingSymlinksInPath(), source = project.appendingPathComponent("README.md"), bytes = try Data(contentsOf: source)
            id = tasks.create(title: "审阅项目副本计划", workspace: project.path, mode: .plan)
            tasks.update(id) { $0.permission = .review; $0.toolGroups = ["files"]; $0.draft = "先制定并用 update_plan 保存两步计划：读取 README.md，然后把它原样复制为 plan-report.md 并回读核对。当前只制定计划，不写文件，等我审阅并点击执行。无需终端、浏览器或额外提问；不要修改 README.md。完成计划后用少于200字简述。" }
            let value: [String: Any] = ["taskID": id, "source": source.path, "sourceHash": AgentFiles.hash(bytes), "result": project.appendingPathComponent("plan-report.md").path, "contextLimit": preferences.contextLimit, "replyLimit": preferences.outputLimit, "maximumRequests": 8]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: manifest, options: .atomic)
        }
        control.showAgentTask(id); return budget
    }
}
