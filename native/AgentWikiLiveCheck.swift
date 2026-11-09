import Foundation
import Darwin

@MainActor enum AgentWikiLiveCheck {
    static func contextReplayCheck() async -> Int32 {
        func option(_ name: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }; return CommandLine.arguments[i + 1] }
        guard !CommandLine.arguments.contains("--live-agent"), let path = option("--check"), let source = option("--context-source") else { return 1 }
        let output = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard output.lastPathComponent.hasPrefix("bluefatfish-wiki-context-") else { return 1 }
        var report: [String: Any] = ["success": false, "modelsCalled": false]
        do {
            let sourceURL = URL(fileURLWithPath: source), original = try Data(contentsOf: sourceURL), historical = try JSONDecoder().decode(AgentTaskRecord.self, from: original)
            guard historical.wikiJob != nil, !(historical.modelReceipts ?? []).isEmpty, !historical.messages.isEmpty else { throw PetError("需要保留的真实 Wiki 模型会话") }
            let profile = output.appendingPathComponent("profile"), tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            guard let task = tasks.task(historical.id) else { throw PetError("真实会话的独立副本不存在") }
            let preferences = PreferencesStore(directory: profile, testing: true).preferences
            guard preferences.contextLimit == 8192, preferences.outputLimit == 512 else { throw PetError("保留8192／512配置") }
            let runtime = AgentRuntime(store: tasks, keychain: PetKeychain(service: "com.xjs.bluefatfish.wiki-context-unused")) { preferences }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let beforeMessages = try encoder.encode(task.messages), beforeReceipts = try encoder.encode(task.modelReceipts)
            let system = try runtime.systemContext(task), definitions = try runtime.toolDefinitions(task, preferences: preferences)
            var admitted = 0
            let messages = try await AgentContext.messages(taskID: task.id, store: tasks, preferences: preferences, key: "", system: system, tools: definitions, requestCheck: { admitted += 1; throw PetError("回放不得调用模型") }, onChange: {})
            let snapshot = try runtime.contextEstimate(task.id), tokens = snapshot.parts.reduce(0) { $0 + $1.tokens }
            let progress = try AgentWiki.progress(task, store: tasks), expected = try task.wikiJob!.plan.paths(root: task.wikiJob!.root)
            let names = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            let originalByID = Dictionary(uniqueKeysWithValues: task.messages.map { ($0.id, $0) })
            let retainedIDs = Set(messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
            guard let actualRead = task.messages.flatMap({ $0.toolCalls ?? [] }).first(where: { $0.name == "read_file" && $0.object["path"] as? String == "README.md" }) else { throw PetError("真实记录缺少 README 读取") }
            let result = try await AgentTools(store: tasks, taskID: task.id).execute(actualRead, gitDirectory: nil)
            let lines = result.text.split(separator: "\n").compactMap { Int($0.split(separator: ":", maxSplits: 1).first ?? "") }
            let after = tasks.task(task.id)!
            let messagesUnchanged = try encoder.encode(after.messages) == beforeMessages
            let receiptsUnchanged = try encoder.encode(after.modelReceipts) == beforeReceipts
            let checks: [String: Bool] = [
                "actualFailedHistoryAndReceiptsUnchanged": messagesUnchanged && receiptsUnchanged,
                "originalSourceRecordBytesUnchanged": try Data(contentsOf: sourceURL) == original,
                "noCompactionOrModelRequest": admitted == 0,
                "projectionRetainsOriginalHumanRequirements": task.messages.filter(\.isHumanInput).allSatisfy { input in messages.contains { $0.id == input.id && $0.content == input.content } },
                "projectedMessagesAreActualOriginalRecords": messages.allSatisfy { originalByID[$0.id]?.content == $0.content },
                "completeToolExchangesRetained": messages.filter { $0.role == "tool" }.allSatisfy { retainedIDs.contains($0.toolCallID ?? "") },
                "nextActualPageAndReadEvidenceSurvive": progress.contains(expected[task.wikiJob!.plan.documents!.first!.title]!) && progress.contains("README.md") && progress.contains("read_sources") && progress.contains("not_written"),
                "writeToolRemainsAvailable": names.contains("write_file") && names.contains("read_file") && names.contains("finish_task"),
                "contextFitsOriginal8192With512Output": tokens + preferences.outputLimit < preferences.contextLimit,
                "summaryAndHistoryBoundaryUnchanged": after.contextSummary == task.contextSummary && after.contextThroughID == task.contextThroughID,
                "actualSourceReadIsBoundedAndResumable": !lines.isEmpty && lines.count <= 30 && result.text.contains("next_offset=") && AgentContext.estimate(result.text) <= 450,
                "manualCompactionCannotSpendWikiAllowance": AgentContext.compactUnavailable(task) == "Wiki 生成任务不支持手动压缩"
            ]
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["historicalMessages"] = task.messages.count; report["historicalReceipts"] = task.modelReceipts?.count ?? 0
            report["inputEstimate"] = tokens; report["context"] = preferences.contextLimit; report["output"] = preferences.outputLimit; report["projectedMessages"] = messages.count; report["actualReadLines"] = lines.count
            report["progress"] = progress; report["projection"] = messages.map { ["id": $0.id, "role": $0.role, "content": $0.content] }
            report["snapshot"] = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
            let executable = Bundle.main.executableURL!; report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
        } catch { report["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-context-report.json"), options: .atomic) } catch { return 1 }
        print(output.appendingPathComponent("wiki-context-report.json").path); return report["success"] as? Bool == true ? 0 : 1
    }
    static func requestGateCheck() async -> Int32 {
        func option(_ name: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }; return CommandLine.arguments[i + 1] }
        guard !CommandLine.arguments.contains("--live-agent"), let path = option("--check"), let source = option("--context-source") else { return 1 }
        let output = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard output.lastPathComponent.hasPrefix("bluefatfish-wiki-gate-") else { return 1 }
        var report: [String: Any] = ["success": false, "modelsCalled": false]
        do {
            let sourceURL = URL(fileURLWithPath: source), sourceFiles = try AgentFiles(workspace: sourceURL.deletingLastPathComponent().path), bytes = try sourceFiles.readData(sourceURL, maximum: 4_000_000), original = try JSONDecoder().decode(AgentTaskRecord.self, from: bytes)
            guard original.messages.filter(\.isHumanInput).count >= 2, !(original.modelReceipts ?? []).isEmpty else { throw PetError("需要已有真实模型会话记录，不创建模拟消息") }
            let tasks = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home")), id = tasks.create(title: "真实历史的请求额度拦截回放", mode: .agent)
            tasks.update(id) { $0.messages = original.messages; $0.contextSummary = nil; $0.contextThroughID = nil; $0.contextManualThroughID = nil }
            var preferences = PetPreferences(); preferences.endpoint = "https://127.0.0.1:9"; preferences.contextTokens = 8192; preferences.replyTokens = 512
            var admitted = 0, blocked = false
            do {
                _ = try await AgentContext.messages(taskID: id, store: tasks, preferences: preferences, key: "", system: "根据真实归档记录整理工作记忆。", tools: [], force: true, requestCheck: { admitted += 1; throw PetError("本轮真实请求额度已用完：回放拦截") }, onChange: {})
            } catch { blocked = error.localizedDescription == "本轮真实请求额度已用完：回放拦截"; report["observedError"] = error.localizedDescription }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let current = tasks.task(id)!
            let checks = ["compactionUsesRequestGateBeforeNetwork": blocked && admitted == 1, "actualMessagesUnchanged": try encoder.encode(current.messages) == encoder.encode(original.messages), "historicalSourceBytesUnchanged": try sourceFiles.readData(sourceURL, maximum: 4_000_000) == bytes, "noNewModelReceipts": (current.modelReceipts ?? []).isEmpty, "summaryAndOffsetUnchangedWhenBlocked": current.contextSummary == nil && current.contextThroughID == nil, "existingBudgetPreserved": preferences.contextLimit == 8192 && preferences.outputLimit == 512]
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["historicalMessages"] = original.messages.count; report["historicalReceipts"] = original.modelReceipts?.count ?? 0; report["sourceHash"] = AgentFiles.hash(bytes)
            let executable = Bundle.main.executableURL!; report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
        } catch { report["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-request-gate-report.json"), options: .atomic) } catch { return 1 }
        print(output.appendingPathComponent("wiki-request-gate-report.json").path); return report["success"] as? Bool == true ? 0 : 1
    }
    static func commandLine() async -> Int32 {
        func option(_ name: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }; return CommandLine.arguments[i + 1] }
        guard CommandLine.arguments.contains("--live-agent"), let path = option("--check") else { print("需要明确开启真实模型及验收目录"); return 1 }
        let output = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), language = option("--wiki-language") ?? "zh"
        guard output.lastPathComponent.hasPrefix("bluefatfish-wiki-live-"), ["zh", "en"].contains(language) else { return 1 }
        let lock = open(output.appendingPathComponent("wiki-live.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return 1 }; defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { print("原真实生成仍在运行"); return 1 }; defer { flock(lock, LOCK_UN) }
        let attempt = UUID().uuidString
        var report: [String: Any] = ["success": false, "modelsCalled": false, "uiValidated": false, "attemptID": attempt]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            let files = try AgentFiles(workspace: output.path)
            guard let grant = try JSONSerialization.jsonObject(with: files.readData(files.resolve("wiki-budget-authorization.json"), maximum: 8192)) as? [String: Any], grant["kind"] as? String == "explicit-user-authorization", let maximum = grant["requestLimit"] as? Int, (1...128).contains(maximum), grant["context"] as? Int == 8192, grant["output"] as? Int == 512 else { throw PetError("缺少本轮 Wiki 真实请求的明确授权") }
            let profile = output.appendingPathComponent("profile"), preferences = PreferencesStore(directory: profile, testing: true).preferences
            guard preferences.contextLimit == 8192, preferences.outputLimit == 512 else { throw PetError("必须保留8192／512配置") }
            let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            guard !tasks.tasks.contains(where: { [.running, .waiting].contains($0.status) }) else { throw PetError("原任务仍在运行或等待处理，请保留记录") }
            let ledgerURL = output.appendingPathComponent("wiki-request-ledger.json")
            var ledger: [[String: Any]] = []
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [[String: Any]] else { throw PetError("原请求账本不可读，停止以保留额度和记录") }; ledger = saved
            }
            guard ledger.count < maximum else { throw PetError("本轮已达真实请求上限，保留全部记录") }; let before = ledger.count
            defer { report["modelsCalled"] = ledger.count > before; report["requests"] = ledger.count; report["requestLimit"] = maximum }
            let keychain = PetKeychain(service: "com.xjs.bluefatfish.credentials"); guard !(try keychain.read("chat")).isEmpty else { throw PetError("请先在应用设置中配置模型") }
            let runtime = AgentRuntime(store: tasks, keychain: keychain) { preferences }
            runtime.modelRequestCheck = {
                guard ledger.count < maximum else { throw PetError("已达本轮\(maximum)次真实请求上限，保留全部记录") }
                ledger.append(["request": ledger.count + 1, "time": ISO8601DateFormatter().string(from: Date())])
                try JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]).write(to: ledgerURL, options: .atomic)
            }
            var finalizing = Set<String>(), finalized = Set<String>()
            runtime.onComplete = { id, _ in
                finalizing.insert(id)
                Task { @MainActor in
                    defer { finalizing.remove(id) }
                    do { try await AgentWiki.finalize(store: tasks, taskID: id); finalized.insert(id) }
                    catch { tasks.update(id) { $0.status = .failed; $0.goalAccepted = nil; $0.events.append(AgentEvent(kind: "wiki", title: "Wiki 校验未完成", detail: error.localizedDescription, status: "failed")) } }
                }
            }
            let marker = "wiki-live-" + language + "-task.json", id: String
            if let data = try? Data(contentsOf: output.appendingPathComponent(marker)), let value = try JSONSerialization.jsonObject(with: data) as? [String: String], let previous = value["id"] {
                guard CommandLine.arguments.contains("--wiki-resume-repaired"), let task = tasks.task(previous), [.failed, .stopped].contains(task.status) else { throw PetError("原生成记录已存在；请核对后明确选择修复续跑") }; try AgentWiki.checkScope(task, store: tasks); id = previous; runtime.start(id)
            } else {
                let source = tasks.tasks.first(where: { $0.kind == nil && $0.workspace == output.appendingPathComponent("workspace").path })?.id ?? tasks.create(title: "真实 Wiki 验收项目", workspace: output.appendingPathComponent("workspace").path, mode: .agent)
                id = try AgentWiki.start(store: tasks, runtime: runtime, sourceID: source, language: language); try write(["id": id, "sourceID": source], marker)
            }
            let executable = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": id, "language": language, "model": preferences.model, "context": 8192, "output": 512, "requestsBefore": before, "requestLimit": maximum], "wiki-live-" + language + "-ready.json")
            let deadline = Date().addingTimeInterval(1800)
            while runtime.isExecuting(id) || finalizing.contains(id) || tasks.task(id)?.status == .ready {
                if Date() > deadline { runtime.cancel(id); throw PetError("实际生成超时，记录保留") }
                try write(["taskID": id, "status": tasks.task(id)?.status.rawValue ?? "missing", "requests": ledger.count, "finalizing": finalizing.contains(id)], "wiki-live-" + language + "-state.json")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let task = tasks.task(id) else { throw PetError("实际任务不可读") }
            let manifest = try AgentWiki.plannedManifest(store: tasks, taskID: id, language: language), validation = try? AgentWiki.validate(task)
            let success = task.status == .completed && task.hasConfirmedWikiCompletion && finalized.contains(id) && manifest?.taskID == id && validation?.hashes == manifest?.pages
            report.merge(["success": success, "appPID": getpid(), "binaryHash": binaryHash, "taskID": id, "language": language, "status": task.status.rawValue, "modelsCalled": ledger.count > before, "requests": ledger.count, "newRequests": ledger.count - before, "requestLimit": maximum, "receipts": task.modelReceipts?.count ?? 0, "context": 8192, "output": 512, "pages": manifest?.pages.count ?? 0, "sources": manifest?.sources ?? [], "failure": task.events.last(where: { $0.status == "failed" })?.detail ?? ""]) { _, value in value }
            if let manifest { try JSONEncoder().encode(manifest).write(to: output.appendingPathComponent("wiki-live-" + language + "-manifest.json"), options: .atomic) }
        } catch { report["error"] = error.localizedDescription }
        do { try write(report, "wiki-live-" + language + "-" + attempt + "-report.json"); try write(report, "wiki-live-" + language + "-report.json") } catch { return 1 }
        print(output.appendingPathComponent("wiki-live-" + language + "-report.json").path); return report["success"] as? Bool == true ? 0 : 1
    }
}
