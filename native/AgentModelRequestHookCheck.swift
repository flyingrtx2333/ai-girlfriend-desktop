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
        import path from 'node:path';
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
          const lastUser = body.messages.findLast(message => message.role === 'user' && typeof message.content === 'string')?.content ?? '';
          const kind = system.startsWith('根据提供的真实任务记录') ? 'recap' :
            contents.some(value => value.startsWith('用户要求原文（仅作为理解记录的依据，不必复述）：')) ? 'compact' :
            text.includes('PUBLIC_QUEUED_SECOND') ? 'queue-retry' : text.includes('PUBLIC_QUEUE_FAILURE_FIRST') ? 'queue-failure' :
            text.includes('PUBLIC_REPLACEMENT_AFTER_FAILURE') ? 'replacement' : text.includes('PUBLIC_LATE_FAILURE_FIRST') ? 'late-failure' :
            text.includes('PUBLIC_STREAM_RETRY') ? 'stream-retry' : text.includes('PUBLIC_STREAM_EOF') ? 'stream-eof' :
            text.includes('PUBLIC_CANCEL_TURN') ? 'cancel' : text.includes('PUBLIC_ERROR_TURN') ? 'error' : 'turn';
          fs.appendFileSync(process.argv[3], 'wire\t' + JSON.stringify({kind, contaminated:text.includes('PUBLIC_DIAGNOSTIC_ONLY'),
            containsInterruptedOutput:text.includes('PUBLIC_INTERRUPTED_ASSISTANT'),
            queuedInputIsLatest:lastUser.startsWith('PUBLIC_QUEUED_SECOND'), queuedAttachmentOnWire:lastUser.includes('[附件编号：'),
            syntheticContinuation:text.includes('继续完成原任务，保留之前的约束。')}) + '\n');
          if (kind === 'stream-eof' || kind === 'cancel') {
            res.writeHead(200, {'Content-Type':'text/event-stream'});
            res.write('data: '+JSON.stringify({choices:[{delta:{content:'PUBLIC_INTERRUPTED_ASSISTANT'}}]})+'\n\n');
            if (kind === 'stream-eof') { res.end(); return; }
          }
          if (kind === 'cancel') {
            const timer = setTimeout(() => res.end(), 15_000);
            res.on('close', () => clearTimeout(timer)); return;
          }
          if (kind === 'queue-failure') {
            const release = path.join(path.dirname(process.argv[3]), 'release-queue-failure');
            const deadline = Date.now() + 8000;
            const timer = setInterval(() => {
              if (!fs.existsSync(release) && Date.now() < deadline) return;
              clearInterval(timer);
              res.writeHead(503, {'Content-Type':'application/json'});
              res.end(JSON.stringify({error:{message:'公开本机传输失败'}}));
            }, 20);
            res.on('close', () => clearInterval(timer)); return;
          }
          if (kind === 'error' || kind === 'late-failure') {
            res.writeHead(500, {'Content-Type':'application/json'});
            res.end(JSON.stringify({error:{message:'公开服务失败 PUBLIC-FIXTURE-ONLY'}})); return;
          }
          const finish = kind === 'compact' && ++compactions === 1 ? 'length' : 'stop';
          const content = kind === 'compact' ? 'PUBLIC_COMPACTION_RESULT' : kind === 'recap' ? 'PUBLIC_RECAP_RESULT' : 'PUBLIC_DIALOGUE_RESULT';
          if (['turn', 'queue-retry', 'replacement'].includes(kind)) {
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
        var executionSettings = AgentGeneralSettings.Settings()
        executionSettings.promptSuggestions = false; executionSettings.skillEvolutionSuggestions = false
        runtime.taskSettings = { executionSettings }
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
        while store.task(cancelling)?.messages.last?.content != "PUBLIC_INTERRUPTED_ASSISTANT", Date() < started { await wait(0.025) }
        guard store.task(cancelling)?.messages.last?.responseState == .streaming else { throw PetError("取消前未收到真实本机流片段") }
        runtime.interrupt(cancelling)
        let cancelled = Date().addingTimeInterval(8)
        while try !rows().dropFirst(beforeCancel).contains(where: { $0.0 == "after" }), Date() < cancelled { await wait(0.025) }
        _ = try await settled(cancelling)
        let cancellation = try ordered(since: beforeCancel)
        checks["actualCancelledTransportRetainsPairedDiagnostic"] = cancellation.map(\.0) == ["before", "wire", "after"] && fieldsMatch(cancellation)
            && store.task(cancelling)?.status == .stopped && cancellation.last?.1["status"] as? String == "cancelled"
            && cancellation.last?.1["error"] is NSNull && cancellation.last?.1["token_usage"] is NSNull
            && store.task(cancelling)?.events.filter { $0.hook?.event == .interrupt && $0.status == "completed" }.count == 1
        checks["stoppingRetainsStreamAsInterruptedText"] = store.task(cancelling)?.messages.last?.responseState == .interrupted &&
            store.task(cancelling)?.messages.last?.content == "PUBLIC_INTERRUPTED_ASSISTANT" && store.task(cancelling)?.messages.last?.isReply == false

        let truncated = store.create(title: "公开流式连接中断", workspace: workspace.path)
        guard runtime.submit("PUBLIC_STREAM_EOF", taskID: truncated) else { throw PetError("流中断样例未开始") }
        let interrupted = try await settled(truncated)
        guard let fragment = interrupted.messages.last else { throw PetError("流片段未保存") }
        checks["missingFinishRetainsFragmentWithoutFinalReply"] = interrupted.status == .failed && fragment.responseState == .interrupted &&
            fragment.content == "PUBLIC_INTERRUPTED_ASSISTANT" && !fragment.isReply && interrupted.modelReceipts?.last?.completed == false
        let fragmentHash = AgentFiles.hash(Data(fragment.content.utf8))
        checks["incompleteReplyCanBeCopiedButCannotBeRated"] = try store.replyMessage(taskID: truncated, messageID: fragment.id, expectedHash: fragmentHash, allowIncomplete: true).content == fragment.content &&
            (try? store.replyMessage(taskID: truncated, messageID: fragment.id, expectedHash: fragmentHash)) == nil
        guard runtime.submit("PUBLIC_STREAM_RETRY", taskID: truncated) else { throw PetError("流中断后未继续") }
        let continued = try await settled(truncated)
        let newWire = try rows().last { $0.0 == "wire" && $0.1["kind"] as? String == "stream-retry" }?.1
        checks["newRequestOmitsInterruptedFragmentAndKeepsOldID"] = newWire?["containsInterruptedOutput"] as? Bool == false &&
            continued.status == .completed && continued.messages.contains { $0.id == fragment.id && $0.responseState == .interrupted } &&
            continued.messages.last?.isReply == true && continued.messages.last?.responseState == nil
        var legacy = interrupted
        legacy.messages = interrupted.messages.map { message in
            var value = message; value.responseState = nil; return value
        }
        let olderAnswer = AgentMessage(role: "assistant", content: "有完整内容的旧版回复")
        legacy.messages.insert(olderAnswer, at: 0)
        let legacyProfile = output.appendingPathComponent("legacy-stream")
        let legacyAgent = legacyProfile.appendingPathComponent("agent")
        try fm.createDirectory(at: legacyAgent, withIntermediateDirectories: true)
        let legacyBytes = try JSONEncoder().encode(legacy)
        try legacyBytes.write(to: legacyProfile.appendingPathComponent("original-task.json"))
        try legacyBytes.write(to: legacyAgent.appendingPathComponent(legacy.id + ".json"))
        let legacyStore = AgentStore(directory: legacyProfile, legacy: [], extensionHome: home)
        let migrated = legacyStore.task(legacy.id)
        checks["legacyRecoveryUsesFailedReceiptAndKeepsOldCompletedText"] = migrated?.messages.last?.responseState == .interrupted &&
            migrated?.messages.last?.id == fragment.id && migrated?.messages.first?.id == olderAnswer.id && migrated?.messages.first?.isReply == true

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

        var visualHistory = compacted
        guard let archivedInput = visualHistory.messages.first, AgentContext.offset(visualHistory) > 0 else {
            throw PetError("压缩样例未保留可核对的原始输入")
        }
        let reference = AgentVisualPart(id: UUID().uuidString, part: 1)
        visualHistory.messages[0].attachmentIDs = [reference.id]
        visualHistory.messages[0].visuals = [reference]
        visualHistory.messages[0].visualsDelivered = true
        let usual = AgentContext.window(visualHistory, maximumImages: 1)
        let limited = AgentContext.window(visualHistory, maximumImages: 1, includeDeliveredImages: false)
        checks["budgetFallbackDropsArchivedDeliveredImageButKeepsInputAndAttachment"] =
            AgentAttachmentVisuals.references(usual, maximum: 1).values.flatMap { $0 } == [reference]
            && AgentAttachmentVisuals.references(limited, maximum: 1).isEmpty
            && limited.first?.id == archivedInput.id && limited.first?.content == archivedInput.content
            && limited.first?.attachmentIDs == [reference.id] && visualHistory.messages[0].visuals == [reference]
        visualHistory.messages[0].visualsDelivered = false
        let undelivered = AgentContext.window(visualHistory, maximumImages: 1, includeDeliveredImages: false)
        checks["budgetFallbackKeepsArchivedUndeliveredImage"] =
            AgentAttachmentVisuals.references(undelivered, maximum: 1).values.flatMap { $0 } == [reference]

        let beforeRecap = try rows().count
        guard runtime.analyze(truncated, recap: true) else { throw PetError("回顾样例未开始") }
        let recapped = try await settled(truncated), recap = try ordered(since: beforeRecap)
        checks["recapIsObservedWithoutReceivingFailedDiagnostics"] = recap.map(\.0) == ["before", "wire", "after"] && fieldsMatch(recap)
            && recap.contains { $0.1["kind"] as? String == "recap" && $0.1["contaminated"] as? Bool == false }
            && recapped.recap?.text == "PUBLIC_RECAP_RESULT"
        checks["recapRequestUsesCompletedHistoryOnly"] = recap.first(where: { $0.0 == "wire" })?.1["containsInterruptedOutput"] as? Bool == false

        let queued = store.create(title: "请求失败时的已发送补充", workspace: workspace.path)
        let attachmentURL = workspace.appendingPathComponent("公开补充.txt")
        let attachmentBytes = Data("公开样例，供失败后继续核对。\n".utf8)
        try attachmentBytes.write(to: attachmentURL)
        let attachment = try await AgentAttachments.importFile(attachmentURL, store: store, taskID: queued)
        let supplements = ["PUBLIC_QUEUED_FIRST · 先核对公开说明", "PUBLIC_QUEUED_SECOND · 继续核对这份附件"]
        guard runtime.submit("PUBLIC_QUEUE_FAILURE_FIRST · 初次查询", taskID: queued) else { throw PetError("排队失败样例未启动") }
        let waitingForWire = Date().addingTimeInterval(6)
        while try !rows().contains(where: { $0.0 == "wire" && $0.1["kind"] as? String == "queue-failure" }), Date() < waitingForWire { await wait(0.025) }
        guard try rows().contains(where: { $0.0 == "wire" && $0.1["kind"] as? String == "queue-failure" }) else { throw PetError("未观察到本机失败请求") }
        guard runtime.submit(supplements[0], taskID: queued), runtime.submit(supplements[1], taskID: queued, attachmentIDs: [attachment.id]),
              let accepted = store.task(queued)?.queuedMessages, accepted.map(\.content) == supplements else { throw PetError("两条补充未实际排队") }
        try Data().write(to: workspace.appendingPathComponent("release-queue-failure"))
        let stoppedWithQueue = try await settled(queued)
        let visible = stoppedWithQueue.messages.filter { supplements.contains($0.content) }
        checks["TransportFailureMakesAcceptedSupplementsVisibleInOrder"] = stoppedWithQueue.status == .failed && stoppedWithQueue.queuedCount == 0 && visible.map(\.id) == accepted.map(\.id) && visible.last?.attachmentIDs == [attachment.id]

        let failureFolder = output.appendingPathComponent("failure-ui/profile/agent", isDirectory: true)
        try fm.createDirectory(at: failureFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in [queued + ".json", queued] {
            try fm.copyItem(at: store.directory.appendingPathComponent(name), to: failureFolder.appendingPathComponent(name))
        }
        let savedFailure = try JSONDecoder().decode(AgentTaskRecord.self, from: Data(contentsOf: failureFolder.appendingPathComponent(queued + ".json")))
        checks["PersistedFailureRetainsExactInputIDsAndAttachmentBytes"] = try savedFailure.messages.filter { supplements.contains($0.content) }.map(\.id) == accepted.map(\.id)
            && Data(contentsOf: AgentAttachments.source(store: store, taskID: queued, id: attachment.id)) == attachmentBytes
        runtime.start(queued)
        let retriedQueue = try await settled(queued)
        let retryWire = try rows().last { $0.0 == "wire" && $0.1["kind"] as? String == "queue-retry" }?.1
        checks["RetryUsesLatestAcceptedSupplementWithoutInventingAnotherUserMessage"] = retriedQueue.status == .completed && retryWire?["queuedInputIsLatest"] as? Bool == true
            && retryWire?["queuedAttachmentOnWire"] as? Bool == true && retryWire?["syntheticContinuation"] as? Bool == false
            && retriedQueue.messages.filter { supplements.contains($0.content) }.map(\.id) == accepted.map(\.id)

        let cleanup = try JSONSerialization.data(withJSONObject: ["hooks": ["StopFailure": [["hooks": [[
            "name": "公开失败收尾", "type": "command", "command": "/usr/bin/touch failure-hook-entered\nexec /bin/sleep 5", "timeout": 8
        ]]]]]])
        let config = try store.hooks.document(project: false, workspace: workspace.path)
        try store.hooks.save(String(decoding: cleanup, as: UTF8.self), project: false, workspace: workspace.path, expectedHash: config.1)
        guard let cleanupHook = try store.hooks.catalog(workspace: workspace.path).first(where: { $0.event == .stopFailure }) else { throw PetError("缺少失败收尾样例") }
        try store.hooks.setEnabled(cleanupHook, true, workspace: workspace.path)
        executionSettings.runningInput = .interrupt
        let racing = store.create(title: "失败收尾期间的插话", workspace: workspace.path)
        guard runtime.submit("PUBLIC_LATE_FAILURE_FIRST", taskID: racing) else { throw PetError("收尾竞争样例未启动") }
        let cleanupMarker = workspace.appendingPathComponent("failure-hook-entered"), cleanupDeadline = Date().addingTimeInterval(7)
        while !fm.fileExists(atPath: cleanupMarker.path), Date() < cleanupDeadline { await wait(0.025) }
        guard fm.fileExists(atPath: cleanupMarker.path), runtime.isExecuting(racing), runtime.submit("PUBLIC_REPLACEMENT_AFTER_FAILURE", taskID: racing) else {
            throw PetError("未能在真实失败收尾期间插话")
        }
        let replacement = try await settled(racing)
        checks["InterruptedFailureCleanupCannotOverwriteTheReplacementTurn"] = try replacement.status == .completed && replacement.summary == "PUBLIC_DIALOGUE_RESULT"
            && replacement.messages.filter { $0.content == "PUBLIC_REPLACEMENT_AFTER_FAILURE" }.count == 1
            && replacement.events.filter { $0.hook?.event == .stopFailure && $0.status == "stopped" }.count == 1
            && rows().filter { $0.0 == "wire" && $0.1["kind"] as? String == "replacement" }.count == 1
        try store.hooks.setEnabled(cleanupHook, false, workspace: workspace.path)

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
        try JSONSerialization.data(withJSONObject: ["taskID": owner, "queuedFailureTaskID": queued, "replacementTaskID": racing, "loopbackRequests": transmitted.count], options: [.sortedKeys]).write(
            to: output.appendingPathComponent("model-request-fixture.json"), options: .atomic)
    }

    func prepareStreamRecoveryUI(_ output: URL, tasks: AgentStore, runtime: AgentRuntime) throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "BlueFatFishAcceptanceOnly") as? Bool == true,
              let port = Int(try String(contentsOf: output.appendingPathComponent("stream-port.txt"), encoding: .utf8)),
              (1...65_535).contains(port) else { throw PetError("流式恢复验收需要独立应用和本机样例服务") }
        let endpoint = "http://127.0.0.1:\(port)/v1"
        store.preferences.endpoint = endpoint
        store.preferences.model = "fixture-observer"
        store.preferences.contextTokens = 8192
        store.preferences.replyTokens = 512
        store.preferences.visionMode = CommandLine.arguments.contains("--vision-context-ui") ? "on" : "off"
        var settings = AgentGeneralSettings.Settings()
        settings.runningInput = .queue
        settings.promptSuggestions = false; settings.skillEvolutionSuggestions = false
        runtime.taskSettings = { settings }
        let marker = output.appendingPathComponent("stream-task-id.txt"), id: String
        if FileManager.default.fileExists(atPath: marker.path) {
            id = try String(contentsOf: marker, encoding: .utf8)
            guard tasks.task(id) != nil else { throw PetError("原流式恢复任务不存在") }
        } else {
            id = tasks.create(title: "公开流式回复恢复", mode: .ask)
            try Data(id.utf8).write(to: marker, options: .atomic)
        }
        control.showAgentTask(id)
        return endpoint
    }
}
