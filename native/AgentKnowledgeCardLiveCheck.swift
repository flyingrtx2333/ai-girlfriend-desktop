import Foundation
import Darwin

@MainActor enum AgentKnowledgeCardLiveCheck {
    static func commandLine() async -> Int32 {
        func option(_ name: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }; return CommandLine.arguments[i + 1] }
        guard CommandLine.arguments.contains("--live-agent"), let path = option("--check"), let sourcePath = option("--cards-source") else { print("需要 --live-agent、--check 及 --cards-source"); return 1 }
        let output = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), language = option("--cards-language") ?? "zh"
        guard output.lastPathComponent.hasPrefix("bluefatfish-cards-"), ["zh", "en"].contains(language) else { print("需要原知识卡片验收目录及有效语言"); return 1 }
        let lock = open(output.appendingPathComponent("cards-live-service.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return 1 }; defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { print("原生成进程仍在运行，请保留"); return 1 }; defer { flock(lock, LOCK_UN) }
        let reportURL = output.appendingPathComponent("cards-live-service-" + language + "-report.json")
        var report: [String: Any] = ["success": false, "uiValidated": false, "modelsCalled": false]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            let profile = output.appendingPathComponent("profile"), indexData = try Data(contentsOf: profile.appendingPathComponent("agent/index.json"))
            let index = try JSONSerialization.jsonObject(with: indexData) as! [String: Any], records = index["tasks"] as? [[String: Any]] ?? []
            guard !records.contains(where: { ["running", "waiting"].contains($0["status"] as? String ?? "") }) else { throw PetError("原验收任务仍运行或等待处理，请保留原记录") }
            let saved = PreferencesStore(directory: profile, testing: true), preferences = saved.preferences
            guard preferences.contextLimit == 8192, preferences.outputLimit == 512 else { throw PetError("必须保留原8192／512预算") }
            let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home")), cards = tasks.knowledgeCards
            let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cards-source-task.json"))) as! [String: String]
            guard let sourceID = owner["id"], let source = tasks.task(sourceID), try cards.scope(source).root == AgentFiles(workspace: sourcePath).root.path else { throw PetError("原项目任务或范围不匹配") }
            func count() -> Int { tasks.tasks.reduce(0) { $0 + (tasks.task($1.id)?.modelReceipts?.count ?? 0) } }
            let maximumRequests = try AgentKnowledgeCardBudget.limit(output)
            let before = count(); guard before < maximumRequests else { throw PetError("整轮验收已达到\(maximumRequests)份回执上限，原记录保留") }
            let keychain = PetKeychain(service: "com.xjs.bluefatfish.credentials")
            guard !(try keychain.read("chat")).isEmpty else { throw PetError("原对话凭据不可用，请在应用中处理") }
            let runtime = AgentRuntime(store: tasks, keychain: keychain) { preferences }
            cards.runtime = runtime
            runtime.modelRequestCheck = { guard count() < maximumRequests else { throw PetError("整轮验收已达到\(maximumRequests)份回执上限，原记录保留") } }
            var finalized: Set<String> = [], finalizing: Set<String> = []
            runtime.onComplete = { id, _ in
                guard tasks.task(id)?.kind == AgentKnowledgeCards.kind else { return }; finalizing.insert(id)
                Task { @MainActor in
                    defer { finalizing.remove(id) }
                    do { try await cards.complete(id); finalized.insert(id) }
                    catch { tasks.update(id) { $0.status = .failed; $0.goalAccepted = nil; $0.events.append(AgentEvent(kind: "knowledge-cards", title: "项目知识校验未完成", detail: error.localizedDescription, status: "failed")) } }
                }
            }
            let executable = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            let marker = output.appendingPathComponent("cards-live-service-" + language + "-task.json"); let id: String
            if let data = try? Data(contentsOf: marker), let value = try JSONSerialization.jsonObject(with: data) as? [String: String], let existing = value["id"], let priorTask = tasks.task(existing) {
                if priorTask.status == .completed, try cards.book(source, language: language).0?.taskID == existing { id = existing; finalized.insert(id) }
                else {
                    let readyURL = output.appendingPathComponent("cards-live-service-" + language + "-ready.json")
                    let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Any]
                    guard [.failed, .stopped].contains(priorTask.status), prior?["taskID"] as? String == existing, let previousHash = prior?["binaryHash"] as? String, previousHash != binaryHash else { throw PetError("原生成任务未成功，请保留并检查；不自动创建替代任务") }
                    if CommandLine.arguments.contains("--cards-new-repaired-attempt"), (priorTask.modelReceipts?.count ?? 0) >= 30 {
                        guard let focus = priorTask.knowledgeJob?.focus else { throw PetError("原分析范围缺失") }
                        id = try await cards.generate(sourceID: sourceID, language: language, focus: focus)
                        try write(["id": id, "repairedFrom": existing], marker.lastPathComponent)
                    } else {
                        guard CommandLine.arguments.contains("--cards-resume-repaired"), (priorTask.modelReceipts?.count ?? 0) < 30 else { throw PetError("原任务已到本次上限，需明确选择修复后的生成流程") }
                        id = existing; runtime.start(id)
                    }
                }
            } else {
                let original = tasks.tasks.compactMap { tasks.task($0.id) }.first { $0.kind == AgentKnowledgeCards.kind && $0.knowledgeJob?.sourceTaskID == sourceID && !($0.knowledgeJob?.focus ?? "").isEmpty }
                guard let focus = original?.knowledgeJob?.focus else { throw PetError("缺少原窗口提交的分析范围") }
                id = try await cards.generate(sourceID: sourceID, language: language, focus: focus)
                try write(["id": id], marker.lastPathComponent)
            }
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": id, "language": language, "model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "requestsBefore": before, "requestLimit": maximumRequests, "uiValidated": false], "cards-live-service-" + language + "-ready.json")
            var observed = Date.distantPast
            while true {
                guard let task = tasks.task(id) else { throw PetError("原任务不可读") }
                if count() > maximumRequests { runtime.cancel(id); throw PetError("整轮验收达到\(maximumRequests)份实际回执上限，原记录保留") }
                if Date().timeIntervalSince(observed) >= 1 {
                    try write(["appPID": getpid(), "taskID": id, "status": task.status.rawValue, "requests": task.modelReceipts?.count ?? 0, "totalRequests": count(), "finalizing": finalizing.contains(id)], "cards-live-service-" + language + "-state.json"); observed = Date()
                }
                if !runtime.isExecuting(id), !finalizing.contains(id), task.status != .ready { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let task = tasks.task(id) else { throw PetError("原任务不可读") }
            let book = try cards.book(source, language: language).0
            let success = task.status == .completed && finalized.contains(id) && book?.taskID == id && Set(book!.cards.map(\.kind)).isSuperset(of: Set(AgentKnowledgeCardKind.allCases)) && book!.cards.allSatisfy { cards.fresh($0, workspace: book!.workspace) }
            report.merge(["success": success, "appPID": getpid(), "binaryHash": binaryHash, "taskID": id, "status": task.status.rawValue, "modelsCalled": count() > before, "newRequests": count() - before, "totalRequests": count(), "requestLimit": maximumRequests, "context": preferences.contextLimit, "output": preferences.outputLimit, "model": preferences.model, "taskRequests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "failure": success ? "" : task.events.last(where: { $0.status == "failed" })?.detail ?? "", "historicalFailures": task.events.filter { $0.status == "failed" }.count, "needsApproval": task.status == .waiting]) { _, new in new }
            if let book { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(book).write(to: output.appendingPathComponent("cards-live-service-" + language + "-book.json"), options: .atomic) }
            cards.stop()
        } catch { report["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
        catch { print("验收报告未保存"); return 1 }
        print(reportURL.path)
        return report["success"] as? Bool == true ? 0 : 1
    }
}
