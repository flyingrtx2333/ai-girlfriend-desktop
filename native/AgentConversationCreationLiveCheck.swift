import AppKit

@MainActor final class AgentConversationCreationLiveBudget {
    static let maximum = 20
    private struct Attempt: Codable { var id = UUID().uuidString; var created = Date() }
    private struct Ledger: Codable { var version = 1, maximum = 20; var configuration: String; var attempts: [Attempt] = [] }
    private let files: AgentFiles, file: URL, authorization: URL, authorizationSignature: String, configuration: String
    private var ledger: Ledger, signature = "missing"
    var used: Int { ledger.attempts.count }
    init(output: URL, preferences: PetPreferences) throws {
        files = try AgentFiles(workspace: output.path); file = try files.literalURL("conversation-creation-request-ledger.json"); authorization = try files.literalURL("conversation-creation-authorization.json")
        guard try files.resolve(authorization.path) == authorization else { throw PetError("真实验收授权不能使用链接") }
        let data = try files.readData(authorization, maximum: 16_384)
        authorizationSignature = try files.entryMetadata(authorization).signature
        let binary = AgentFiles.hash(try Data(contentsOf: Bundle.main.executableURL!)), inputs = try files.readData(files.literalURL("input-hashes.json"), maximum: 16_384)
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any], auth["scope"] as? String == "conversation-creation",
              auth["maximumRequests"] as? Int == Self.maximum, auth["contextLimit"] as? Int == 8192, auth["replyLimit"] as? Int == 512, auth["model"] as? String == "deepseek-flash",
              auth["candidateHash"] as? String == binary, auth["inputsHash"] as? String == AgentFiles.hash(inputs),
              (auth["directory"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == output.resolvingSymlinksInPath(),
              preferences.contextLimit == 8192, preferences.outputLimit == 512, preferences.model == "deepseek-flash" else { throw PetError("缺少本轮会话创建最多20次的独立授权，或候选、输入、deepseek-flash、8192／512配置已变化") }
        configuration = Self.fingerprint(preferences) + ":" + binary + ":" + AgentFiles.hash(inputs)
        if FileManager.default.fileExists(atPath: file.path) {
            signature = try files.entryMetadata(file).signature; ledger = try JSONDecoder().decode(Ledger.self, from: files.readData(file, maximum: 65_536))
            guard ledger.version == 1, ledger.maximum == Self.maximum, ledger.configuration == configuration, ledger.attempts.count <= Self.maximum,
                  Set(ledger.attempts.map(\.id)).count == ledger.attempts.count, try files.entryMetadata(file).signature == signature else { throw PetError("会话创建请求账本已变化，原记录保留") }
        } else { ledger = Ledger(configuration: configuration); try save(ledger) }
    }
    private static func fingerprint(_ p: PetPreferences) -> String { AgentFiles.hash(Data([p.endpoint, p.model, String(p.contextLimit), String(p.outputLimit)].joined(separator: "\n").utf8)) }
    private func save(_ next: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.writeData(encoder.encode(next), to: file, permissions: 0o600, expectedTarget: signature)
        signature = try files.entryMetadata(file).signature; ledger = next
    }
    func request(preferences: PetPreferences) throws {
        guard configuration.hasPrefix(Self.fingerprint(preferences) + ":"), used < Self.maximum,
              try files.entryMetadata(authorization).signature == authorizationSignature else { throw PetError("会话创建真实请求已达20次，或授权／配置已变化；保留原任务和账本") }
        var next = ledger; next.attempts.append(Attempt()); try save(next)
    }
    static func requireFresh(_ output: URL, used: Int) throws {
        guard used == 0, !FileManager.default.fileExists(atPath: output.appendingPathComponent("conversation-creation-started.json").path) else { throw PetError("本目录已开始验收，不能重放、替换任务或清空账本") }
    }
}

private struct AgentConversationCreationIntent: Decodable {
    var scope: String, roleName: String, rolePrompt: String, readPrompt: String, automationName: String, timeZone: String
    var scheduleLeadSeconds: Int
}

@MainActor extension AppDelegate {
    func runAgentConversationCreationPreflight(_ output: URL) async {
        var checks: [String: Bool] = [:], attempts = 0, errorText: String?
        do {
            guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--manual-ui") else { throw PetError("前置检查不授权真实请求或混用窗口入口") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("前置检查禁止模型传输") }
            let marker = output.appendingPathComponent("conversation-creation-preflight-started.json"), fm = FileManager.default
            guard !fm.fileExists(atPath: marker.path) else { throw PetError("本轮前置检查已开始，不能重放") }
            try JSONSerialization.data(withJSONObject: ["appPID": getpid()]).write(to: marker, options: .atomic); await wait(0.25)
            var p = PetPreferences(); p.model = "deepseek-flash"; p.contextTokens = 8192; p.replyTokens = 512
            let auth = output.appendingPathComponent("conversation-creation-authorization.json"), ledger = output.appendingPathComponent("conversation-creation-request-ledger.json")
            var rejected = false; do { _ = try AgentConversationCreationLiveBudget(output: output, preferences: p) } catch { rejected = true }
            checks["missingAuthorizationBlocksBeforeCreatingLedger"] = rejected && !fm.fileExists(atPath: ledger.path)
            let negative = try JSONSerialization.data(withJSONObject: ["scope": "preflight-negative-only", "maximumRequests": 0])
            try negative.write(to: auth); rejected = false
            do { _ = try AgentConversationCreationLiveBudget(output: output, preferences: p) } catch { rejected = true }
            checks["wrongScopeAndZeroAllowanceCannotCreateLedger"] = rejected && !fm.fileExists(atPath: ledger.path)
            let retained = output.appendingPathComponent("retained-invalid-authorization.json"); try fm.moveItem(at: auth, to: retained); try fm.createSymbolicLink(at: auth, withDestinationURL: retained)
            rejected = false; do { _ = try AgentConversationCreationLiveBudget(output: output, preferences: p) } catch { rejected = true }
            checks["authorizationLinkIsRejectedAndOriginalBytesRemain"] = try rejected && Data(contentsOf: retained) == negative && !fm.fileExists(atPath: ledger.path)
            let started = output.appendingPathComponent("conversation-creation-started.json"); try Data("preflight-negative-marker".utf8).write(to: started)
            rejected = false; do { try AgentConversationCreationLiveBudget.requireFresh(output, used: 0) } catch { rejected = true }; checks["startedDirectoryCannotReplay"] = rejected
            let empty = output.appendingPathComponent("unused-root"); try fm.createDirectory(at: empty, withIntermediateDirectories: true)
            rejected = false; do { try AgentConversationCreationLiveBudget.requireFresh(empty, used: 1) } catch { rejected = true }; checks["usedAllowanceCannotRestartWithMissingMarker"] = rejected
            checks["maximumIsTwentyAndNoEarlierLedgerIsUsed"] = AgentConversationCreationLiveBudget.maximum == 20 && !fm.fileExists(atPath: ledger.path)
            checks["productionDraftToolsRemainAvailableInAskMode"] = ["agents": "draft_agent", "automations": "draft_automation"].allSatisfy { group, tool in AgentTools.definitions(mode: .ask, groups: [group]).contains { ($0["function"] as? [String: Any])?["name"] as? String == tool } }
            checks["noRequestReplyReceiptOrActiveJobWasCreated"] = attempts == 0 && !runtime.isWorking && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty }
        } catch { errorText = error.localizedDescription }
        var report: [String: Any] = ["appPID": getpid(), "binaryHash": (try? Data(contentsOf: Bundle.main.executableURL!)).map(AgentFiles.hash) ?? "", "checks": checks, "success": errorText == nil && checks.count == 8 && checks.values.allSatisfy { $0 }, "blockedModelAttempts": attempts, "modelTransmissionAuthorized": false]
        if let errorText { report["error"] = errorText }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("conversation-creation-preflight-result.json"), options: .atomic)
    }

    func runAgentConversationCreationLiveCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], budget: AgentConversationCreationLiveBudget?, taskIDs: [String] = []
        var allowed = Set<String>(), allowedAutomation: String?, roleID: String?, requestedDate: Date?
        func write(_ object: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--manual-ui"), !usesBackgroundAttachmentCheck,
                  output.lastPathComponent.hasPrefix("bluefatfish-conversation-creation-live-") else { throw PetError("真实会话创建需独立目录和可审阅的实际窗口") }
            let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; preferences.persona = ""
            let limit = try AgentConversationCreationLiveBudget(output: output, preferences: preferences); budget = limit
            try AgentConversationCreationLiveBudget.requireFresh(output, used: limit.used)
            let files = try AgentFiles(workspace: output.path), inputs = try JSONDecoder().decode([String: String].self, from: files.readData(files.literalURL("input-hashes.json"), maximum: 16_384))
            guard Set(inputs.keys) == ["project/README.md", "conversation-creation-intent.json"] else { throw PetError("验收输入名单无效") }
            for (name, hash) in inputs { let url = try files.literalURL(name), data = try files.readData(url, maximum: 100_000); guard try files.resolve(name) == url, AgentFiles.hash(data) == hash else { throw PetError("公开验收输入已变化") } }
            let intent = try JSONDecoder().decode(AgentConversationCreationIntent.self, from: files.readData(files.literalURL("conversation-creation-intent.json"), maximum: 16_384))
            guard intent.scope == "conversation-creation", intent.scheduleLeadSeconds == 300, intent.timeZone == "Asia/Shanghai", intent.roleName == "README 只读核对员", intent.automationName == "README 一次性核对", intent.rolePrompt.utf8.count <= 3000, intent.readPrompt.utf8.count <= 3000 else { throw PetError("验收目标或执行范围不匹配") }
            let project = try files.resolve("project"), original = try files.readData(files.literalURL("project/README.md"), maximum: 100_000), binaryHash = AgentFiles.hash(try Data(contentsOf: Bundle.main.executableURL!))
            guard project.path == output.appendingPathComponent("project").standardizedFileURL.path else { throw PetError("验收项目不能使用链接或更换目录") }
            try write(["appPID": getpid(), "binaryHash": binaryHash, "maximumRequests": 20], "conversation-creation-started.json")
            store.preferences = preferences; try store.savePreferences(); ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            guard tasks.tasks.count == 1, tasks.tasks.compactMap({ tasks.task($0.id) }).allSatisfy({ $0.kind == "companion" && $0.messages.isEmpty }), try tasks.agents.list().isEmpty else { throw PetError("目录已有任务或角色，保留记录且不重放") }
            let service = tasks.automations
            guard !FileManager.default.fileExists(atPath: service.directory.appendingPathComponent("definitions.json").path) else { throw PetError("目录已有自动化，不启动调度") }
            service.start(store: tasks, runtime: runtime); guard service.isStarted, service.values.isEmpty else { throw PetError(service.error ?? "目录已有自动化") }
            runtime.modelRequestCheck = { [weak self] in
                let executing = tasks.tasks.filter { runtime.isExecuting($0.id) }
                guard let self, executing.count == 1, let task = executing.first, task.workspace == project.path else { throw PetError("请求不属于本轮唯一公开项目任务") }
                let scheduled = allowedAutomation.flatMap { id in service.values.first { $0.id == id } }
                let validRun = scheduled?.current?.taskID == task.id && task.automation?.automationID == allowedAutomation && task.agent?.profile.id == roleID && task.agent?.profile.readOnly == true && task.agent?.profile.network == false && task.automation?.readOnly == true && task.automation?.network == false && task.automation?.permission == .review
                guard allowed.contains(task.id) && task.mode == .ask || validRun else { throw PetError("请求不属于已审阅的本轮创建或执行流程") }
                try limit.request(preferences: self.store.preferences)
            }
            @MainActor func stage(_ name: String, _ fields: [String: Any]) throws {
                let file = output.appendingPathComponent("conversation-creation-stage-" + name + ".json"); guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("阶段记录已存在，不能覆盖") }
                try write(fields.merging(["appPID": getpid(), "binaryHash": binaryHash, "usedRequests": limit.used]) { _, new in new }, file.lastPathComponent)
            }
            @MainActor func complete(_ id: String) async throws {
                let deadline = Date().addingTimeInterval(240)
                while runtime.isRunning(id) && Date() < deadline { if runtime.pendingReview(id) != nil { throw PetError("验收出现未授权确认或缺失信息，原任务保留") }; await wait(0.25) }
                guard !runtime.isRunning(id), let task = tasks.task(id), task.status == .completed, task.messages.contains(where: \.isReply), task.modelReceipts?.contains(where: { $0.completed && $0.requestedModel == "deepseek-flash" }) == true else { throw PetError("真实任务尚未完成，保留任务及请求账本：" + id) }
            }
            let creator = tasks.create(title: "会话生成只读角色", workspace: project.path, mode: .ask, workMode: .general); taskIDs.append(creator); allowed = [creator]
            control.showAgentTask(creator); control.show(tab: "chat")
            guard runtime.submit(intent.rolePrompt, taskID: creator) else { throw PetError(runtime.submissionError ?? "角色要求未提交") }; try await complete(creator); allowed = []
            guard let creatorTask = tasks.task(creator), creatorTask.agentDrafts?.count == 1, let proposal = creatorTask.agentDrafts?.first else { throw PetError("真实模型未生成唯一角色草稿") }
            _ = try AgentProfileDrafts.load(proposal.id, taskID: creator, store: tasks); roleID = proposal.profile.id; report["profileID"] = proposal.profile.id; report["roleCreatorTaskID"] = creator
            let savedRoles = try tasks.agents.list()
            checks["realModelCreatesUnactivatedRoleProposal"] = proposal.profile.name == intent.roleName && !proposal.profile.enabled && proposal.profile.readOnly && !proposal.profile.network && proposal.savedAt == nil && savedRoles.isEmpty
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("角色提案与要求不符，原输出保留") }
            try stage("role-draft-ready", ["taskID": creator, "draftID": proposal.id, "profileID": proposal.profile.id, "proposal": String(decoding: try JSONEncoder().encode(proposal.profile), as: UTF8.self)])
            let reviewDeadline = Date().addingTimeInterval(1800); var role: AgentProfile?
            while Date() < reviewDeadline {
                if tasks.task(creator)?.agentDrafts?.first?.savedAt != nil, let saved = try? tasks.agents.profile(proposal.profile.id), saved.name == proposal.profile.name, saved.description == proposal.profile.description, saved.instructions == proposal.profile.instructions, saved.readOnly, !saved.network, saved.permission == .review, Set(saved.tools) == ["read_file", "search_files", "list_directory"], (saved.skills ?? []).isEmpty, (saved.mcpServers ?? []).isEmpty, saved.model.isEmpty || saved.model == "deepseek-flash" { role = saved; break }; await wait(0.25)
            }
            guard let role else { throw PetError("角色尚未在实际表单审阅、保存并启用") }
            try stage("role-saved-ready", ["taskID": creator, "profileID": role.id])
            while Date() < reviewDeadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("continue-role-use").path) { await wait(0.25) }
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("continue-role-use").path) else { throw PetError("等待角色窗口复核结束，已有任务和请求账本保留") }
            let use = try tasks.agents.createTask(role.id, store: tasks, workspace: project.path, workMode: .general); taskIDs.append(use); tasks.update(use) { $0.mode = .ask; $0.title = "生成角色实际核对 README" }; allowed = [use]
            report["roleUseTaskID"] = use
            guard runtime.submit(intent.readPrompt, taskID: use) else { throw PetError(runtime.submissionError ?? "角色读取未提交") }; try await complete(use); allowed = []
            checks["savedGeneratedRoleActuallyReadsREADME"] = tasks.task(use)?.events.contains { $0.kind == "tool" && $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("README.md") } == true
            try stage("role-use-completed", ["taskID": use])
            let when = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + Double(intent.scheduleLeadSeconds)); requestedDate = when
            let at = ISO8601DateFormatter().string(from: when), prompt = "/automation 创建一次性本机计划，名称为「" + intent.automationName + "」，在 " + at + " 只运行一次，时区 " + intent.timeZone + "。任务要求：" + intent.readPrompt + "输出使用独立任务。先给我可审阅草稿，执行者和启用状态由我在表单选择，不要立即运行。"
            let planner = tasks.create(title: "会话生成一次性计划", workspace: project.path, mode: .ask, workMode: .general); taskIDs.append(planner); allowed = [planner]; control.showAgentTask(planner); control.show(tab: "chat")
            report["automationCreatorTaskID"] = planner
            guard runtime.submit(prompt, taskID: planner) else { throw PetError(runtime.submissionError ?? "计划要求未提交") }; try await complete(planner); allowed = []
            guard let plannerTask = tasks.task(planner), plannerTask.automationDrafts?.count == 1, let plan = plannerTask.automationDrafts?.first else { throw PetError("真实模型未生成唯一计划草稿") }
            _ = try AgentAutomationDrafts.load(plan.id, taskID: planner, store: tasks); allowedAutomation = plan.automation.id; report["automationID"] = plan.automation.id
            checks["realModelCreatesExactPausedOneTimeSchedule"] = plan.automation.name == intent.automationName && plan.automation.schedule.frequency == .once && plan.automation.schedule.date == when && plan.automation.schedule.timeZone == intent.timeZone && plan.automation.output == .independent && !plan.automation.enabled && plan.savedAt == nil && service.values.isEmpty
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("计划提案与时间要求不符，原输出保留") }
            try stage("automation-draft-ready", ["taskID": planner, "draftID": plan.id, "automationID": plan.automation.id, "profileID": role.id, "requestedAt": at, "requestedUnix": when.timeIntervalSince1970])
            var reviewed: AgentAutomation?; let scheduleDeadline = when.addingTimeInterval(240)
            while Date() < when {
                if let saved = service.values.first(where: { $0.id == plan.automation.id }), saved.name == plan.automation.name, saved.prompt == plan.automation.prompt, saved.enabled, !saved.archived, saved.executor == "agent:" + role.id, saved.workspace == project.path, saved.schedule.frequency == .once, saved.schedule.date == when, saved.schedule.timeZone == intent.timeZone, saved.output == .independent, saved.readOnly, !saved.network, saved.permission == .review, tasks.task(planner)?.automationDrafts?.first?.savedAt != nil { reviewed = saved; break }; await wait(0.25)
            }
            guard let reviewed else { throw PetError("计划尚未在实际表单审阅、选择生成角色并启用，未补跑") }
            try stage("automation-enabled", ["automationID": reviewed.id, "requestedAt": at, "nextUnix": reviewed.nextRun.map { $0.timeIntervalSince1970 as Any } ?? NSNull()])
            var run: AgentAutomationRun?
            while Date() < scheduleDeadline {
                let history = try service.history(automationID: reviewed.id).runs
                if let current = history.first, current.status.terminal { run = current; break }
                if let id = service.values.first(where: { $0.id == reviewed.id })?.current?.taskID, runtime.pendingReview(id) != nil { throw PetError("实际定时运行需要额外确认，未自动批准") }; await wait(0.25)
            }
            if let runTask = run?.taskID { taskIDs.append(runTask) }
            guard let run, run.status == .completed, run.trigger == "schedule", run.scheduled == when, let runTask = run.taskID, let actual = tasks.task(runTask) else { throw PetError("实际一次性计划未完成，未手动补跑") }
            allowedAutomation = nil
            checks["actualTimerRunsReviewedGeneratedRoleAtRequestedTime"] = actual.agent?.profile.id == role.id && actual.automation?.automationID == reviewed.id && actual.workspace == project.path && actual.events.contains { $0.kind == "automation" && $0.title == "按计划运行" }
            checks["scheduledRoleActuallyReadsPublicREADMEWithRealReceipt"] = actual.events.contains { $0.kind == "tool" && $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("README.md") } && actual.modelReceipts?.contains { $0.completed && $0.requestedModel == "deepseek-flash" } == true && actual.messages.contains(where: \.isReply)
            checks["onlyOneScheduledRunAndNoManualReplay"] = try service.history(automationID: reviewed.id).total == 1 && !service.values.first(where: { $0.id == reviewed.id })!.enabled
            checks["publicSourceBytesRemainOriginal"] = try Data(contentsOf: project.appendingPathComponent("README.md")) == original
            checks["allFourTasksKeepRealRepliesAndBoundedReceipts"] = taskIDs.count == 4 && taskIDs.allSatisfy { id in tasks.task(id)?.messages.contains(where: \.isReply) == true && tasks.task(id)?.modelReceipts?.contains { $0.completed && $0.requestedModel == "deepseek-flash" } == true } && (1...20).contains(limit.used)
            report["sourceHash"] = AgentFiles.hash(original); report["profileID"] = role.id; report["automationID"] = reviewed.id; report["requestedAt"] = at; report["scheduledRunID"] = run.id
            report["answers"] = [use,runTask].map { tasks.task($0)?.messages.last(where: \.isReply)?.content ?? "" }; report["creationReplies"] = [creator,planner].map { tasks.task($0)?.messages.last(where: \.isReply)?.content ?? "" }; report["requiresIndependentAnswerReview"] = true
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("真实生成或运行检查未通过，所有记录保留") }
            control.showAgentTask(runTask); control.show(tab: "chat"); try stage("complete-ready", ["taskIDs": taskIDs, "checks": checks, "requiresIndependentAnswerReview": true])
            let finishDeadline = Date().addingTimeInterval(1800)
            while Date() < finishDeadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-conversation-creation-ui").path) { await wait(0.25) }
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-conversation-creation-ui").path) else { throw PetError("最终实际窗口复核未结束") }
        } catch { report["error"] = error.localizedDescription }
        allowed = []; allowedAutomation = nil; agentRuntime?.stopAll()
        if let service = agentStore?.automations { for value in service.values where value.id == (report["automationID"] as? String) && value.enabled { do { try service.setPaused(value.id, paused: true) } catch { report["pauseError"] = error.localizedDescription } }; report["allPlansPaused"] = service.values.allSatisfy { !$0.enabled }; service.stop() }
        let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.05) }
        report["checks"] = checks; report["taskIDs"] = taskIDs; report["usedRequests"] = budget?.used ?? 0; report["maximumRequests"] = 20; report["appPID"] = getpid(); report["activeJobs"] = agentRuntime?.isWorking == true; report["requestedUnix"] = requestedDate?.timeIntervalSince1970
        report["success"] = report["error"] == nil && report["pauseError"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentRuntime?.isWorking != true
        report["binaryHash"] = (try? Data(contentsOf: Bundle.main.executableURL!)).map(AgentFiles.hash)
        try? write(report, "conversation-creation-result.json")
    }
}
