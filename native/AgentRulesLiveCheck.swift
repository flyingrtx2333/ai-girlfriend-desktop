import AppKit

@MainActor final class AgentRulesLiveBudget {
    private struct Attempt: Codable { var id = UUID().uuidString; var created = Date() }
    private struct Ledger: Codable { var version = 1; var maximum: Int; var configuration: String; var attempts: [Attempt] = [] }
    private let directory: URL, file: URL, configuration: String
    let maximum: Int
    private var ledger: Ledger, signature = "missing"
    var used: Int { ledger.attempts.count }
    init(output: URL, preferences: PetPreferences, globOnly: Bool = false) throws {
        let stem = globOnly ? "rules-glob-live" : "rules-live", scope = globOnly ? "rules-glob" : "rules"
        maximum = globOnly ? 6 : 16
        directory = output; file = output.appendingPathComponent(stem + "-request-ledger.json")
        let files = try AgentFiles(workspace: output.path), data = try files.readData(files.literalURL(stem + "-authorization.json"), maximum: 16_384)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any], auth["scope"] as? String == scope,
              auth["maximumRequests"] as? Int == maximum, auth["contextLimit"] as? Int == 8192, auth["replyLimit"] as? Int == 512, auth["model"] as? String == "deepseek-flash",
              (auth["directory"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == output.resolvingSymlinksInPath(),
              preferences.contextLimit == 8192, preferences.outputLimit == 512, preferences.model == "deepseek-flash" else { throw PetError("缺少本轮规则最多\(maximum)次的明确授权，或 deepseek-flash、8192／512 配置已变化") }
        configuration = Self.fingerprint(preferences)
        if FileManager.default.fileExists(atPath: file.path) {
            signature = try files.entryMetadata(file).signature
            ledger = try JSONDecoder().decode(Ledger.self, from: files.readData(file, maximum: 65_536))
            guard ledger.version == 1, ledger.maximum == maximum, ledger.configuration == configuration, ledger.attempts.count <= maximum, Set(ledger.attempts.map(\.id)).count == ledger.attempts.count,
                  try files.entryMetadata(file).signature == signature else { throw PetError("规则 请求账本或配置已变化，保留原记录") }
        } else { ledger = Ledger(maximum: maximum, configuration: configuration); try save(ledger) }
    }
    private static func fingerprint(_ p: PetPreferences) -> String { AgentFiles.hash(Data([p.endpoint, p.model, String(p.contextLimit), String(p.outputLimit)].joined(separator: "\n").utf8)) }
    private func save(_ value: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = try AgentFiles(workspace: directory.path); try files.writeData(encoder.encode(value), to: file, permissions: 0o600, expectedTarget: signature)
        signature = try files.entryMetadata(file).signature; ledger = value
    }
    func request(preferences: PetPreferences) throws {
        guard Self.fingerprint(preferences) == configuration, used < maximum else { throw PetError("规则真实请求已达\(maximum)次或配置已变化，原记录与未完成任务保留") }
        var next = ledger; next.attempts.append(Attempt()); try save(next)
    }
}

@MainActor extension AppDelegate {
    func runAgentRulesLiveCheck(_ output: URL, globOnly: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], budget: AgentRulesLiveBudget?, ids: [String] = []
        let stem = globOnly ? "rules-glob-live" : "rules-live", maximum = globOnly ? 6 : 16
        do {
            guard CommandLine.arguments.contains("--live-agent"), !["--manual-ui", "--local-rule-check", "--plugin-rule-check", "--plugin-agent-live-check"].contains(where: CommandLine.arguments.contains) else { throw PetError("真实规则验收不能混用其他检查入口") }
            guard CommandLine.arguments.contains(globOnly ? "--rules-glob-live-check" : "--rules-live-check"), !CommandLine.arguments.contains(globOnly ? "--rules-live-check" : "--rules-glob-live-check") else { throw PetError("规则验收范围与入口不一致") }
            let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
            let limit = try AgentRulesLiveBudget(output: output, preferences: preferences, globOnly: globOnly); budget = limit
            let marker = output.appendingPathComponent(stem + "-started.json")
            guard !FileManager.default.fileExists(atPath: marker.path), limit.used == 0 else { throw PetError("本目录已开始真实规则验收，保留原任务与账本，不重放") }
            try JSONSerialization.data(withJSONObject: ["appPID": getpid(), "maximumRequests": maximum]).write(to: marker, options: .atomic)
            store.preferences = preferences; try store.savePreferences(); ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let project = output.appendingPathComponent("project"), sourceNames = ["README.md", "docs/README.md", "package.json"]
            let originals = try Dictionary(uniqueKeysWithValues: sourceNames.map { ($0, try Data(contentsOf: project.appendingPathComponent($0))) })
            var role = AgentProfile(name: "规则只读验收", description: "公开文件和本机只读查询", instructions: "保留文件，遵循当前有效规则；只使用已授予的只读工具，不能写入、委派或联网。")
            role.permission = .automatic; role.tools = ["read_file", "run_command", "list_rules", "read_rule"]; role.enabled = true
            let previous = try tasks.agents.document(); var profiles = try tasks.agents.decode(previous.0); profiles.append(role)
            try tasks.agents.save(tasks.agents.encode(profiles), expectedHash: previous.1)
            let setup = tasks.create(title: "规则配置准备", workspace: project.path, mode: .ask, workMode: .general)
            func make(_ name: String, _ trigger: AgentRuleTrigger, _ body: String, project: Bool = true, patterns: [String] = [], description: String = "") throws -> AgentLocalRuleItem {
                try tasks.rules.create(name: name, text: AgentRuleDocument.text(name: name, trigger: trigger, description: description, patterns: patterns, body: body), project: project, task: tasks.task(setup)!)
            }
            let always = try make("machine-review", .always, "当用户查询本机物理内存与磁盘时，先实际执行只读终端 /usr/sbin/sysctl -n hw.memsize 与 /bin/df -k /。答复只用一个两列表格：项目｜实测值；项目仅物理内存、根分区可用，单位保留工具输出。表格后补一行来源，列出实际命令。不建议清理，不改动文件。", project: false)
            let manual = try make("readme-review", .manual, "审阅项目说明时，先用 read_file 读取 README.md 第1至45行。只列三项：完整名称、原生框架、源码构建命令；每项都带 README.md:L行号 引用。不执行构建，不修改文件。")
            let decision = try make("package-review", .decision, "先用 read_file 读取 package.json，按实际字段核对 name 与 scripts.native:build。答复仅列这两个字段的实际值，每项标明 package.json:L行号。保留文件，不运行构建。", description: "用户要求核对 package.json 的包名和原生构建脚本时采用。")
            let glob = try make("docs-review", .glob, "读取 docs/README.md 后，先实际 read_file 读取 package.json，对照两份实际文件核对源码构建方式。答复给出一致或不同，列出实际构建命令，并同时引用 docs/README.md 与 package.json 的真实行号；保留文件，不执行构建。", patterns: ["docs/README.md"])
            var allowed: [String: String] = [:]
            runtime.modelRequestCheck = { [weak self] in
                let executing = tasks.tasks.filter { runtime.isExecuting($0.id) }
                guard let self, self.store.preferences.model == "deepseek-flash", executing.count == 1,
                      executing.allSatisfy({ allowed[$0.id] == ($0.workspace ?? "<none>") && $0.model == "deepseek-flash" && $0.agent?.profile.id == role.id && $0.agent?.readOnly == true && $0.agent?.network == false && $0.mode == .ask && $0.agent?.tools == Set(role.tools) }) else { throw PetError("真实请求不属于本轮只读规则任务") }
                try limit.request(preferences: self.store.preferences)
            }
            let cases: [(String, String?, String)] = [
                ("始终规则与无工作区终端", nil, "查一下这台 Mac 的物理内存和根分区剩余空间。"),
                ("手动规则审阅公开 README", project.path, "@rule:" + manual.invocation + " 按选择的规则审阅当前项目。"),
                ("模型判断规则核对软件包", project.path, "核对当前项目的软件包名称和原生构建脚本；先查看适用规则，再按规则完成。"),
                ("文件规则对照实际来源", project.path, "请读取 docs/README.md 的前45行，说明项目名称和源码构建方式。")
            ]
            func completedCalls(_ task: AgentTaskRecord) -> [AgentToolCall] {
                let completed = Set(task.events.filter { $0.kind == "tool" && $0.status == "completed" }.compactMap(\.toolCallID))
                return task.messages.flatMap { $0.toolCalls ?? [] }.filter { completed.contains($0.id) }
            }
            func readPaths(_ task: AgentTaskRecord) throws -> [String] {
                let files = try AgentFiles(workspace: task.workspace)
                return try completedCalls(task).filter { $0.name == "read_file" }.compactMap { call in try (call.object["path"] as? String).map { files.relative(try files.resolve($0)) } }
            }
            for (index, value) in cases.enumerated() {
                if globOnly && index != 3 { continue }
                let id = try tasks.agents.createTask(role.id, store: tasks, workspace: value.1, workMode: .general); ids.append(id); allowed[id] = value.1 ?? "<none>"
                tasks.update(id) { $0.title = value.0; $0.mode = .ask }
                guard runtime.submit(value.2, taskID: id) else { throw PetError(runtime.submissionError ?? "真实规则输入未提交") }
                let end = Date().addingTimeInterval(240)
                while runtime.isRunning(id) && Date() < end { await wait(0.1) }
                if runtime.isRunning(id) { runtime.cancel(id); throw PetError("真实规则观察到期，保留原进程结果和账本，不重放") }
                guard let task = tasks.task(id), task.status == .completed else { throw PetError("真实规则任务未完成：" + (tasks.task(id)?.events.last(where: { $0.status == "failed" })?.detail ?? value.0)) }
                checks["case\(index + 1)HasActualModelReply"] = task.messages.contains(where: \.isReply) && task.modelReceipts?.contains(where: { $0.completed && $0.requestedModel == "deepseek-flash" }) == true
                let calls = completedCalls(task)
                switch index {
                case 0:
                    checks["alwaysRuleAppliesToActualNoWorkspaceTerminal"] = task.workspace == nil && task.localRuleIDs?.contains(always.id) == true && calls.contains { $0.name == "run_command" }
                case 1:
                    checks["explicitManualChoiceReadsActualREADME"] = try task.activeLocalRules?.contains(where: { $0.id == manual.id && $0.workspace == project.path }) == true && readPaths(task).contains("README.md")
                case 2:
                    checks["modelDecisionLoadsActualRuleThenReadsPackage"] = try task.activeLocalRules?.contains(where: { $0.id == decision.id }) == true && calls.contains { $0.name == "read_rule" && $0.object["id"] as? String == decision.id } && readPaths(task).contains("package.json")
                default:
                    let paths = try readPaths(task)
                    checks["actualDocsReadActivatesGlobBeforePackageComparison"] = task.activeLocalRules?.contains(where: { $0.id == glob.id }) == true && paths.firstIndex(of: "docs/README.md").map { first in paths.firstIndex(of: "package.json").map { $0 > first } ?? false } == true
                }
                report["completedCases"] = ids.count
            }
            let finished = ids.compactMap(tasks.task)
            checks["allPublicSourcesRemainOriginal"] = try originals.allSatisfy { try Data(contentsOf: project.appendingPathComponent($0.key)) == $0.value }
            checks["onlyGrantedReadOnlyToolsExecuted"] = finished.allSatisfy { completedCalls($0).allSatisfy { ["read_file", "run_command", "list_rules", "read_rule", "load_tools", "update_plan", "finish_task", "read_task_history"].contains($0.name) } && $0.agent?.readOnly == true && $0.agent?.network == false }
            checks["separateBoundedLedgerRetainsEveryAttempt"] = (1...maximum).contains(limit.used) && finished.reduce(0) { $0 + ($1.modelReceipts?.count ?? 0) } <= limit.used
            report["rules"] = [always, manual, decision, glob].map { ["id": $0.id, "name": $0.invocation, "sha256": $0.sha256, "trigger": $0.definition!.trigger.rawValue] }
            report["sourceHashes"] = originals.mapValues(AgentFiles.hash)
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["taskIDs"] = ids; report["answers"] = ids.map { agentStore?.task($0)?.messages.last(where: \.isReply)?.content ?? "" }; report["requiresIndependentAnswerReview"] = true
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentRuntime?.isWorking != true
        report["appPID"] = getpid(); report["usedRequests"] = budget?.used ?? 0; report["maximumRequests"] = maximum; report["globOnly"] = globOnly; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(stem + "-result.json"), options: .atomic)
    }

    func runAgentRulesMetadataReplayCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        do {
            guard let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("replay-source.json"))) as? [String: Any] else { throw PetError("回放输入需要JSON对象") }
            guard let path = input["directory"] as? String, let id = input["taskID"] as? String, UUID(uuidString: id) != nil, let hashes = input["hashes"] as? [String: String], !hashes.isEmpty else { throw PetError("缺少原始真实失败记录") }
            let root = URL(fileURLWithPath: path), files = try AgentFiles(workspace: path)
            func originalBytesMatch() throws -> Bool { try hashes.allSatisfy { name, hash in try files.fileHash(files.literalURL(name), maximum: 20_000_000) == hash } }
            guard try originalBytesMatch() else { throw PetError("原始记录已经变化，停止只读回放") }
            let task = try JSONDecoder().decode(AgentTaskRecord.self, from: files.readData(files.literalURL("profile/agent/" + id + ".json"), maximum: 20_000_000))
            let rules = AgentRules(profile: root.appendingPathComponent("profile"), sharedHome: root.appendingPathComponent("shared-home"), plugins: AgentPlugins(profile: root.appendingPathComponent("profile")))
            guard let reference = task.activeLocalRules?.first else { throw PetError("原始文件规则未激活") }
            let item = try rules.current(reference.id, task: task), context = try rules.context(task).text
            let wrongIDs = task.messages.flatMap { $0.toolCalls ?? [] }.filter { $0.name == "read_rule" }.compactMap { $0.object["id"] as? String }
            checks["usesActualFailedModelTaskAndGlobReference"] = task.status == .failed && task.modelReceipts?.count == 7 && item.definition?.trigger == .glob && reference.workspace == task.workspace
            checks["originalWrongInvocationAndHashRemainRecorded"] = wrongIDs == [item.invocation, item.sha256]
            checks["loadedRuleExposesItsExactResolvableToolID"] = context.contains("id=" + reference.id) && item.id == reference.id
            checks["loadedBodyAndAlreadyActiveHintArePresent"] = context.contains(item.definition!.body) && context.contains("无需再次调用read_rule")
            checks["sourceHashIsSeparatelyLabeled"] = context.contains("sha256=" + item.sha256) && item.sha256 != reference.id
            checks["readonlyAskScopeRemainsIntact"] = task.mode == .ask && task.agent?.readOnly == true && task.agent?.network == false
            let definition = AgentTools.definitions(mode: .ask).first { ($0["function"] as? [String: Any])?["name"] as? String == "read_rule" }?["function"] as? [String: Any]
            checks["toolDescriptionExplainsAlreadyLoadedRules"] = (definition?["description"] as? String)?.contains("无需重复读取") == true
            guard let ledger = try JSONSerialization.jsonObject(with: files.readData(files.literalURL("rules-live-request-ledger.json"))) as? [String: Any] else { throw PetError("原始请求账本无效") }
            checks["original16AttemptsAndAllSourceBytesRemainUnchanged"] = try (ledger["attempts"] as? [Any])?.count == 16 && originalBytesMatch()
            report["actualSourceTaskID"] = id; report["ruleContext"] = context; report["protectedOriginalFiles"] = hashes.count
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["modelRequests"] = 0
        report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("rules-metadata-replay-result.json"), options: .atomic)
    }
}

