import AppKit

@MainActor extension AppDelegate {
    func runAgentIndexCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("repo", isDirectory: true), scratch = output.appendingPathComponent("tmp", isDirectory: true)
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: repo.path)
            let fixture = [
                "refund.csv": "plan,automatic_limit,manual_queue\nstandard,1200,海盐-7319\n",
                "docs/rules.md": "# 自动退款\n未发货订单在配置的金额上限以内才可自动退款，否则转人工队列。上限及队列来自 refund.csv。\n引用标记：O'Reilly。\n",
                "src/refund.py": "import csv\nfrom pathlib import Path\n\ndef decide(amount, shipped=False):\n    with (Path(__file__).parents[1] / 'refund.csv').open() as f:\n        rule = next(csv.DictReader(f))\n    if not shipped and amount <= int(rule['automatic_limit']):\n        return 'auto'\n    return rule['manual_queue']\n",
                "remove-me.txt": "临时资料-929\n",
                ".gitignore": "ignored.md\n",
                "ignored.md": "不得进入索引-928\n",
                ".env": "PUBLIC_FIXTURE=不得进入索引-928\n",
                "credentials.py": "PUBLIC_FIXTURE='不得进入索引-928'\n"
            ]
            for (path, content) in fixture { try files.writeData(Data(content.utf8), to: files.resolve(path)) }
            let outside = output.appendingPathComponent("outside.txt"); try Data("不得进入索引-928\n".utf8).write(to: outside)
            try fm.createSymbolicLink(at: repo.appendingPathComponent("outside-link.txt"), withDestinationURL: outside)
            let initialized = try await AgentCommand().run(command: [try AgentGit.executablePath(), "init", "-b", "main"].map(AgentGit.quote).joined(separator: " "), workspace: repo, scratch: scratch, network: false, timeout: 10, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true)
            guard !initialized.failed else { throw PetError(initialized.text) }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let id = tasks.create(title: "真实项目索引", workspace: repo.path, mode: .ask)
            let tools = AgentTools(store: tasks, taskID: id)
            func run(_ name: String, _ values: [String: Any]) async throws -> AgentIndexResult {
                let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)), directory = try tools.gitDirectory(for: call)
                guard try tools.approvalReason(for: call, gitDirectory: directory) == nil else { throw PetError("测试项目不应访问外部元数据") }
                let result = try await tools.execute(call, gitDirectory: directory), decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(AgentIndexResult.self, from: Data(result.text.utf8))
            }
            let first = try await run("index_project", [:]), unchanged = try await run("index_project", [:])
            let ignored = try await run("search_project", ["query": "不得进入索引-928"])
            checks["actualSQLiteIndexRespectsGitIgnoreAndPrivatePaths"] = first.index.files == 4 && ignored.matches.isEmpty
            checks["unchangedFilesAreNotReindexed"] = unchanged.index.updatedFiles == 0 && first.index.revision == unchanged.index.revision
            let chinese = try await run("search_project", ["query": "海盐"]), quoted = try await run("search_project", ["query": "O'Reilly"])
            checks["shortChineseAndQuotedQueriesMatchActualSources"] = chinese.matches.contains { $0.path == "refund.csv" && $0.text.contains("1200") && $0.sha256 == AgentFiles.hash(Data(fixture["refund.csv"]!.utf8)) && $0.source.hasSuffix("#L1") } && quoted.matches.contains { $0.path == "docs/rules.md" }
            try files.remove(files.resolve("remove-me.txt"))
            checks["deletedFilesDisappearFromIndex"] = try await run("search_project", ["query": "临时资料-929"]).matches.isEmpty
            let index = try AgentProjectIndex(workspace: repo.path, storage: tasks.directory)
            checks["indexStoredPrivatelyOutsideProject"] = (try fm.attributesOfItem(atPath: index.directory.appendingPathComponent("index.sqlite").path)[.posixPermissions] as? Int) == 0o600 && !index.directory.path.hasPrefix(repo.path + "/")
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("索引原生检查未通过，未调用模型") }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("需要 --live-agent 验收真实模型检索") }
            let profile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.contextTokens = max(32_768, p.contextTokens); p.replyTokens = 4096; store.preferences = p
            let independent = try await AgentCommand().run(command: "/usr/bin/awk -F, 'NR==2 {print (1499 <= $2 ? \"auto\" : \"manual\") \" \" $3}' refund.csv", workspace: repo, scratch: scratch, network: false, timeout: 5, readOnly: true)
            checks["independentSourceCalculation"] = !independent.failed && independent.stdout == "manual 海盐-7319\n"
            runtime.submit("请用 search_project 定位自动退款规则，再用 read_file 核对。未发货订单金额 1499 可以自动退款吗？上限多少？不能自动退款时去哪一个人工队列？请引用实际文件及行号，不修改项目。", taskID: id)
            let deadline = Date().addingTimeInterval(100)
            while Date() < deadline, let task = tasks.task(id), [.ready, .running, .waiting].contains(task.status) {
                if task.status == .waiting { runtime.cancel(id); throw PetError("只读检索不应要求额外操作") }; await wait(0.1)
            }
            let task = tasks.task(id)!
            checks["realModelRetrievesAndVerifiesBusinessFacts"] = task.status == .completed && task.summary.contains("1200") && task.summary.contains("海盐-7319") && task.summary.contains("refund.csv") && task.events.contains { $0.title == "search_project" && $0.status == "completed" } && task.events.contains { $0.title == "read_file" && $0.status == "completed" }
            report["live"] = ["model": p.model, "status": task.status.rawValue, "result": task.summary]
            try files.writeData(Data(fixture["refund.csv"]!.replacingOccurrences(of: "1200", with: "1800").utf8), to: files.resolve("refund.csv"))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: files.resolve("refund.csv").path)
            let updated = try await run("search_project", ["query": "海盐"])
            checks["incrementalIndexReflectsActualFileChanges"] = updated.index.updatedFiles == 1 && updated.matches.contains { $0.path == "refund.csv" && $0.text.contains("1800") && !$0.text.contains("1200") } && updated.index.revision != first.index.revision
            let sourceHashes = try Dictionary(uniqueKeysWithValues: ["refund.csv", "docs/rules.md", "src/refund.py"].map { ($0, AgentFiles.hash(try files.readData(files.resolve($0)))) })
            let wikiID = try AgentWiki.start(store: tasks, runtime: runtime, sourceID: id), wikiDeadline = Date().addingTimeInterval(200)
            checks["repeatedWikiGenerationUsesSameActiveTask"] = try AgentWiki.start(store: tasks, runtime: runtime, sourceID: id) == wikiID
            while Date() < wikiDeadline, let wiki = tasks.task(wikiID), [.ready, .running, .waiting].contains(wiki.status) {
                if wiki.status == .waiting { runtime.cancel(wikiID); throw PetError("Wiki 生成不应请求修改源代码或运行命令") }; await wait(0.1)
            }
            let verificationDeadline = Date().addingTimeInterval(20)
            while Date() < verificationDeadline, tasks.task(wikiID)?.status == .completed, (try? AgentWiki.manifest(store: tasks, taskID: wikiID)) == nil { await wait(0.1) }
            let wikiTask = tasks.task(wikiID)!, manifest = try AgentWiki.manifest(store: tasks, taskID: wikiID)
            checks["realModelGeneratesVerifiedWikiWithActualSources"] = wikiTask.status == .completed && wikiTask.goalAccepted == true && manifest?.pages.count == 4 && manifest?.sources.contains("refund.csv") == true
            let pages = try AgentWiki.required.map { String(decoding: try files.readData(files.resolve($0)), as: UTF8.self) }.joined(separator: "\n")
            checks["wikiUsesUpdatedRulesAndRealCitations"] = pages.contains("1800") && pages.contains("海盐-7319") && pages.contains("src/refund.py") && pages.contains("refund.csv") && !pages.contains("1200")
            checks["wikiDoesNotReadIgnoredOrCredentialContent"] = manifest?.sources.contains("ignored.md") == false && !pages.contains("不得进入索引-928")
            checks["wikiGenerationDoesNotModifySourceFiles"] = try sourceHashes.allSatisfy { key, value in AgentFiles.hash(try files.readData(files.resolve(key))) == value }
            let restricted = AgentTools(store: tasks, taskID: wikiID), unsafe = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{\"path\":\"src/refund.py\",\"content\":\"bad\"}")
            do { _ = try restricted.approvalReason(for: unsafe); checks["wikiCannotWriteOutsideItsDocumentation"] = false } catch { checks["wikiCannotWriteOutsideItsDocumentation"] = true }
            let ignoredRead = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"ignored.md\"}")
            do { _ = try await restricted.execute(ignoredRead); checks["wikiReadBoundaryIsEnforcedDuringExecution"] = false } catch { checks["wikiReadBoundaryIsEnforcedDuringExecution"] = true }
            let scan = AgentToolCall(id: UUID().uuidString, name: "search_files", arguments: "{\"pattern\":\"不得进入\"}")
            do { _ = try await restricted.execute(scan); checks["wikiCannotBypassIndexThroughRawSearch"] = false } catch { checks["wikiCannotBypassIndexThroughRawSearch"] = true }
            report["wiki"] = ["status": wikiTask.status.rawValue, "result": wikiTask.summary, "pages": manifest?.pages.keys.sorted() ?? [], "sources": manifest?.sources ?? []]
            if wikiTask.status != .completed { report["wikiEvents"] = wikiTask.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] } }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 真实生成未通过") }
            let reuseID = tasks.create(title: "新任务引用 Repo Wiki", workspace: repo.path, mode: .ask)
            runtime.submit("请用 project_wiki 读取项目 Wiki，再用 read_file 核对当前退款配置。未发货订单金额 1499 现在可以自动退款吗？当前上限是多少？引用实际文件及行号，不修改文件。", taskID: reuseID)
            let reuseDeadline = Date().addingTimeInterval(90)
            while Date() < reuseDeadline, let reuse = tasks.task(reuseID), [.ready, .running, .waiting].contains(reuse.status) {
                if reuse.status == .waiting { runtime.cancel(reuseID); throw PetError("Wiki 只读引用不应要求其他操作") }; await wait(0.1)
            }
            let reuse = tasks.task(reuseID)!
            checks["newTaskUsesWikiAndVerifiesCurrentSource"] = reuse.status == .completed && reuse.summary.contains("1800") && reuse.summary.contains("1499") && reuse.events.contains { $0.title == "project_wiki" && $0.status == "completed" } && reuse.events.contains { $0.title == "read_file" && $0.status == "completed" }
            report["reuse"] = ["status": reuse.status.rawValue, "result": reuse.summary]
            try files.writeData(Data(fixture["refund.csv"]!.replacingOccurrences(of: "1200", with: "2100").utf8), to: files.resolve("refund.csv"))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: files.resolve("refund.csv").path)
            _ = try await run("index_project", [:])
            checks["wikiDetectsChangedSourceAfterIndexRefresh"] = try AgentWiki.status(store: tasks, taskID: wikiID) == "需更新"
            let knowledge = AgentKnowledgeWindow(store: tasks, taskID: id)
            checks.merge(await knowledge.checkLayout(query: "海盐", output: output)) { _, value in value }; knowledge.close()
            tasks.selectedID = wikiID; control.show(tab: "chat"); checks.merge(await control.checkAgentLayout(output, includeArtifacts: false)) { _, value in value }
        } catch { report["error"] = error.localizedDescription }
        report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil; report["checks"] = checks
        report["scope"] = "Actual local SQLite index and public Git fixtures. Actual configured model locates and reads business rules; independent awk reads the source CSV. Actual model generates four Wiki pages against changed rules. No production repository changes, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("index-report.json")) }
    }
}
