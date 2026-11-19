import AppKit

@MainActor extension AppDelegate {
    func runModelRequestHookCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["appPID": getpid(), "modelRequests": 0]
        do { try await checkModelRequestHooks(output, checks: &checks) }
        catch { report["error"] = error.localizedDescription }
        report["checks"] = checks
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("model-request-hook-report.json"), options: .atomic)
    }

    private func checkModelRequestHooks(_ output: URL, checks: inout [String: Bool]) async throws {
        let fm = FileManager.default, profile = output.appendingPathComponent("profile"), home = output.appendingPathComponent("shared-home")
        let workspace = output.appendingPathComponent("Harbor"), source = output.appendingPathComponent("Source")
        let codex = source.appendingPathComponent(".codex"), scripts = codex.appendingPathComponent("hooks")
        for dir in [workspace, home, scripts] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let fixture = output.appendingPathComponent("model-fixture.mjs"), port = output.appendingPathComponent("port.txt")
        let trace = workspace.appendingPathComponent("fixture-trace.tsv"), key = "PUBLIC-FIXTURE-ONLY"
        let program = #"""
        import fs from 'node:fs';
        import http from 'node:http';
        let compactions = 0;
        const count = {prompt_tokens: 45, completion_tokens: 7, total_tokens: 52, prompt_tokens_details:{cached_tokens:4}, completion_tokens_details:{reasoning_tokens:2}};
        const server = http.createServer(async (req, res) => {
          if (req.url !== '/v1/chat/completions' || req.method !== 'POST' || req.headers.authorization !== 'Bearer PUBLIC-FIXTURE-ONLY') {
            res.writeHead(400); res.end(); return;
          }
          const chunks = [];
          for await (const chunk of req) chunks.push(chunk);
          const body = JSON.parse(Buffer.concat(chunks));
          const contents = body.messages.map(message => message.content).filter(value => typeof value === 'string');
          const system = contents[0], text = contents.join('\n');
          const kind = system.startsWith('根据提供的真实任务记录') ? 'recap' :
            contents.some(value => value.startsWith('用户要求原文（仅作为理解记录的依据，不必复述）：')) ? 'compact' :
            text.includes('PUBLIC_CANCEL_TURN') ? 'cancel' : text.includes('PUBLIC_ERROR_TURN') ? 'error' : 'turn';
          fs.appendFileSync(process.argv[3], 'wire\t' + JSON.stringify({kind, contaminated:text.includes('PUBLIC_DIAGNOSTIC_ONLY')}) + '\n');
          if (kind === 'cancel') {
            const timer = setTimeout(() => {res.writeHead(504); res.end();}, 15_000);
            res.on('close', () => clearTimeout(timer)); return;
          }
          if (kind === 'error') {
            res.writeHead(500, {'Content-Type':'application/json'});
            res.end(JSON.stringify({error:{message:'公开服务失败 PUBLIC-FIXTURE-ONLY'}})); return;
          }
          const finish = kind === 'compact' && ++compactions === 1 ? 'length' : 'stop';
          const content = kind === 'compact' ? 'PUBLIC_COMPACTION_RESULT' : kind === 'recap' ? 'PUBLIC_RECAP_RESULT' : 'PUBLIC_DIALOGUE_RESULT';
          if (kind === 'turn') {
            res.writeHead(200, {'Content-Type':'text/event-stream'});
            res.write('data: '+JSON.stringify({model:'fixture-observer',choices:[{delta:{content},finish_reason:'stop'}]})+'\n\n');
            res.end('data: '+JSON.stringify({usage:count})+'\n\ndata: [DONE]\n\n'); return;
          }
          res.writeHead(200, {'Content-Type':'application/json'});
          res.end(JSON.stringify({model:'fixture-observer',choices:[{message:{content},finish_reason:finish}],usage:count}));
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(server.address().port)));
        """#
        try Data(program.utf8).write(to: fixture)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node"); process.arguments = [fixture.path, port.path, trace.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: port.path), process.isRunning, Date() < deadline { await wait(0.025) }
        guard let number = Int(try String(contentsOf: port, encoding: .utf8)), (1...65_535).contains(number) else { throw PetError("本机模型协议样例未启动") }

        let hook = #"""
        #!/bin/sh
        IFS= read -r payload
        printf '%s\t%s\n' "$1" "$payload" >> "$QODER_PROJECT_DIR/fixture-trace.tsv" || exit 15
        if [ "$1" = background ]; then printf '%s\n' PUBLIC_DIAGNOSTIC_ONLY_BACKGROUND; exit 1; fi
        printf '{"continue":false,"systemMessage":"PUBLIC_DIAGNOSTIC_ONLY_WARNING","hookSpecificOutput":{"hookEventName":"%s","additionalContext":"PUBLIC_DIAGNOSTIC_ONLY_CONTEXT"}}\n' "$2"
        """#
        try Data(hook.utf8).write(to: scripts.appendingPathComponent("observer.sh"))
        let toml = #"""
        [[hooks.PreModelRequest]]
        matcher = "^won't-match$"
        [[hooks.PreModelRequest.hooks]]
        name = "公开请求前诊断"
        type = "command"
        command = '/bin/sh "$QODER_HOOK_ROOT/observer.sh" before PreModelRequest'
        timeout = 4
        """#
        try Data(toml.utf8).write(to: codex.appendingPathComponent("config.toml"))
        let hooks = try JSONSerialization.data(withJSONObject: ["hooks": ["Interrupt": [["hooks": [
            ["name": "公开请求取消提示", "type": "command", "command": "/usr/bin/true"]
        ]]], "PostModelRequest": [["hooks": [
            ["name": "公开请求后诊断", "type": "command", "command": "/bin/sh \"$QODER_HOOK_ROOT/observer.sh\" after PostModelRequest", "timeout": 4],
            ["name": "公开后台诊断", "type": "command", "command": "/bin/sh \"$QODER_HOOK_ROOT/observer.sh\" background PostModelRequest", "timeout": 4, "async": true]
        ]]]]], options: [.sortedKeys])
        try hooks.write(to: codex.appendingPathComponent("hooks.json"))

        let store = AgentStore(directory: profile, legacy: [], extensionHome: home)
        try store.organization.register(workspace.path, mode: .coding)
        let owner = store.create(title: "公开请求诊断", workspace: workspace.path)
        _ = try await AgentGit(store: store, taskID: owner, directory: AgentGit.metadata(workspace: workspace.path, creating: true)).initialize()
        await store.dataImport.detect(.codex, root: source, category: .configuration, workspace: workspace.path)
        let imports = store.dataImport.preview.filter { $0.issue == nil }
        checks["bothCodexSourcesPreviewModelEvents"] = Set(imports.map(\.title)) == ["config.toml", "hooks.json"]
            && imports.contains { $0.preview.contains("PreModelRequest") } && imports.contains { $0.preview.contains("PostModelRequest") }
        for item in imports { try await AgentStandaloneDataImport.install(item, root: source, store: store) }
        let definitions = try store.hooks.catalog(workspace: workspace.path)
        checks["observerDefinitionsAreDisabledAndIgnoreMatcher"] = definitions.count == 4 && definitions.filter { $0.event.observesModelRequest }.count == 3
            && definitions.allSatisfy { $0.event.diagnosticOnly && $0.matcher.isEmpty && !store.hooks.enabled($0) }
        for definition in definitions { try store.hooks.setEnabled(definition, true, workspace: workspace.path) }
        let invalid = try JSONSerialization.data(withJSONObject: ["hooks": ["PreModelRequest": [["hooks": [
            ["type": "prompt", "prompt": "公开样例"], ["type": "command", "command": "/usr/bin/true", "asyncRewake": true]
        ]]]]])
        checks["diagnosticEntriesRejectModelRecursionAndWake"] = try store.hooks.parse(invalid, file: codex.appendingPathComponent("validate.json"), scope: "验收", workspace: workspace.path)
            .allSatisfy { $0.diagnostic != nil }

        let vault = PetKeychain(service: "com.xjs.bluefatfish.request-hook-check", configurationFile: output.appendingPathComponent("fixture-key.json"), migrateLegacy: false)
        try vault.write(key, account: "chat")
        let runtime = AgentRuntime(store: store, keychain: vault) {
            var p = PetPreferences(); p.model = "fixture-observer"; p.endpoint = "http://127.0.0.1:\(number)/v1"
            p.contextTokens = 8192; p.replyTokens = 512; p.visionMode = "off"; return p
        }
        runtime.taskSettings = { var s = AgentGeneralSettings.Settings(); s.promptSuggestions = false; s.skillEvolutionSuggestions = false; return s }
        var requests = 0, permit = true
        runtime.modelRequestCheck = { guard permit, requests < 12 else { throw PetError("本机样例拒绝传输") }; requests += 1 }
        func rows() throws -> [(String, [String: Any])] {
            guard fm.fileExists(atPath: trace.path) else { return [] }
            return try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { throw PetError("诊断样例记录无效") }
                return (String(parts[0]), try AgentConfigurationJSON.object(Data(parts[1].utf8)))
            }
        }
        func settled(_ id: String) async throws -> AgentTaskRecord {
            let end = Date().addingTimeInterval(12)
            while runtime.isBusy(id), Date() < end { await wait(0.025) }
            guard !runtime.isBusy(id), let task = store.task(id) else { runtime.cancel(id); throw PetError("本机任务未结束") }
            return task
        }
        func ordered(since: Int) throws -> [(String, [String: Any])] { try Array(rows().dropFirst(since)).filter { $0.0 != "background" } }
        func fieldsMatch(_ pair: [(String, [String: Any])]) -> Bool {
            guard let first = pair.first?.1, let last = pair.last?.1 else { return false }
            return first["model"] as? String == "fixture-observer" && last["model"] as? String == "fixture-observer"
                && first["turn_id"] as? String != nil && first["turn_id"] as? String == last["turn_id"] as? String
                && first["session_id"] as? String != nil && first["session_id"] as? String == last["session_id"] as? String
                && first["transcript_path"] is NSNull && last["transcript_path"] is NSNull
        }

        guard runtime.submit("PUBLIC_SUCCESS_TURN", taskID: owner) else { throw PetError("正常对话未开始") }
        let success = try await settled(owner), first = try ordered(since: 0)
        checks["normalRequestRunsDiagnosticsAroundActualTransport"] = first.map(\.0) == ["before", "wire", "after"]
            && fieldsMatch(first) && first.last?.1["status"] as? String == "completed" && success.status == .completed && success.summary == "PUBLIC_DIALOGUE_RESULT"
        checks["postReportsProviderUsageWithoutInventingCounters"] = (first.last?.1["token_usage"] as? [String: Int]) == ["input_tokens":45, "output_tokens":7, "total_tokens":52, "cached_input_tokens":4, "reasoning_output_tokens":2]
            && first.last?.1["error"] is NSNull
        checks["diagnosticOutputStaysOnlyInTaskRecords"] = success.hookContexts?.isEmpty != false
            && success.messages.allSatisfy { !$0.content.contains("PUBLIC_DIAGNOSTIC_ONLY") }
            && success.events.contains { $0.title == "公开后台诊断" && $0.hook?.delivery == "recorded" && $0.status == "failed" }
            && success.events.filter { $0.hook?.event.observesModelRequest == true }.allSatisfy { $0.hook?.effect?.halt == nil && $0.hook?.effect?.context.isEmpty == true && $0.hook?.effect?.systemMessage == nil }

        let failing = store.create(title: "公开请求失败", workspace: workspace.path), beforeFailure = try rows().count
        guard runtime.submit("PUBLIC_ERROR_TURN", taskID: failing) else { throw PetError("失败样例未开始") }
        let failure = try await settled(failing), errorRows = try ordered(since: beforeFailure), error = errorRows.last?.1["error"] as? String
        checks["httpFailureReportsRedactedErrorAndAbsentUsage"] = errorRows.map(\.0) == ["before", "wire", "after"] && fieldsMatch(errorRows)
            && failure.status == .failed && errorRows.last?.1["status"] as? String == "failed" && errorRows.last?.1["token_usage"] is NSNull
            && error?.contains("公开服务失败") == true && error?.contains(key) == false

        let cancelling = store.create(title: "公开请求取消", workspace: workspace.path), beforeCancel = try rows().count
        guard runtime.submit("PUBLIC_CANCEL_TURN", taskID: cancelling) else { throw PetError("取消样例未开始") }
        let started = Date().addingTimeInterval(8)
        while try !rows().dropFirst(beforeCancel).contains(where: { $0.1["kind"] as? String == "cancel" }), Date() < started { await wait(0.025) }
        guard Date() < started else { throw PetError("取消前未收到真实本机请求") }
        runtime.interrupt(cancelling)
        let cancelled = Date().addingTimeInterval(8)
        while try !rows().dropFirst(beforeCancel).contains(where: { $0.0 == "after" }), Date() < cancelled { await wait(0.025) }
        _ = try await settled(cancelling)
        let cancellation = try ordered(since: beforeCancel)
        checks["actualCancelledTransportRetainsPairedDiagnostic"] = cancellation.map(\.0) == ["before", "wire", "after"] && fieldsMatch(cancellation)
            && store.task(cancelling)?.status == .stopped && cancellation.last?.1["status"] as? String == "cancelled"
            && cancellation.last?.1["error"] is NSNull && cancellation.last?.1["token_usage"] is NSNull
            && store.task(cancelling)?.events.filter { $0.hook?.event == .interrupt && $0.status == "completed" }.count == 1

        let compact = store.create(title: "公开请求重试", workspace: workspace.path), beforeCompact = try rows().count
        let original = [AgentMessage(role: "user", content: "PUBLIC_ORIGINAL"), AgentMessage(role: "assistant", content: String(repeating: "Public research history with retained evidence. ", count: 100)), AgentMessage(role: "user", content: "PUBLIC_CURRENT")]
        store.update(compact) { $0.messages = original; $0.status = .completed }
        guard runtime.submit("/compact", taskID: compact) else { throw PetError("手动压缩未启动") }
        let compacted = try await settled(compact), attempts = try ordered(since: beforeCompact)
        checks["compactionRetryGetsTwoPairsOnOneTurn"] = attempts.map(\.0) == ["before", "wire", "after", "before", "wire", "after"]
            && fieldsMatch(Array(attempts.prefix(3))) && fieldsMatch(Array(attempts.suffix(3)))
            && attempts.first?.1["turn_id"] as? String == attempts.last?.1["turn_id"] as? String
            && attempts.filter { $0.0 == "wire" }.allSatisfy { $0.1["kind"] as? String == "compact" }
            && compacted.contextSummary == "PUBLIC_COMPACTION_RESULT" && compacted.messages.map(\.id) == original.map(\.id)
            && compacted.modelReceipts?.map(\.finishReason) == ["length", "stop"]

        let beforeRecap = try rows().count
        guard runtime.analyze(owner, recap: true) else { throw PetError("回顾样例未开始") }
        let recapped = try await settled(owner), recap = try ordered(since: beforeRecap)
        checks["recapIsObservedWithoutReceivingFailedDiagnostics"] = recap.map(\.0) == ["before", "wire", "after"] && fieldsMatch(recap)
            && recap.contains { $0.1["kind"] as? String == "recap" && $0.1["contaminated"] as? Bool == false }
            && recapped.recap?.text == "PUBLIC_RECAP_RESULT"

        let denied = store.create(title: "公开传输门禁", workspace: workspace.path), count = try rows().count
        permit = false
        guard runtime.submit("PUBLIC_BLOCKED_BEFORE_WIRE", taskID: denied) else { throw PetError("本机门禁样例未开始") }
        _ = try await settled(denied)
        checks["blockedBeforeTransportCreatesNoObservation"] = try rows().count == count
        let final = try rows(), transmitted = final.filter { $0.0 == "wire" }, traceText = try String(contentsOf: trace, encoding: .utf8)
        checks["allTransportsStayLocalAndDiagnosticsStayOutOfWire"] = transmitted.count == requests
            && transmitted.allSatisfy { $0.1["contaminated"] as? Bool == false }
            && final.filter { $0.0 != "wire" }.allSatisfy { $0.1["transcript_path"] is NSNull && $0.1["prompt"] == nil && $0.1["messages"] == nil }
            && !traceText.contains(key)
        store.selectedID = owner
        try JSONSerialization.data(withJSONObject: ["taskID": owner, "loopbackRequests": transmitted.count], options: [.sortedKeys]).write(
            to: output.appendingPathComponent("model-request-fixture.json"), options: .atomic)
    }
}
