import AppKit

@MainActor extension AppDelegate {
    func runHookLifecycleCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["appPID": getpid(), "modelRequests": 0]
        do { try await checkHookLifecycle(output, checks: &checks) }
        catch { report["error"] = error.localizedDescription }
        report["checks"] = checks
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("hook-lifecycle-report.json"), options: .atomic)
    }

    private func checkHookLifecycle(_ output: URL, checks: inout [String: Bool]) async throws {
        let fm = FileManager.default, profile = output.appendingPathComponent("profile"), home = output.appendingPathComponent("shared-home")
        let project = output.appendingPathComponent("Harbor"), source = output.appendingPathComponent("Source")
        let codex = source.appendingPathComponent(".codex"), scripts = codex.appendingPathComponent("hooks")
        for dir in [project, home, scripts] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let reply = "PUBLIC_REPLY_7008", summary = "PUBLIC_COMPACT_SUMMARY_5193"
        let server = output.appendingPathComponent("session-fixture.mjs"), port = output.appendingPathComponent("fixture-port.txt")
        let trace = output.appendingPathComponent("fixture-requests.jsonl")
        let serverScript = #"""
        import fs from 'node:fs';
        import http from 'node:http';
        const server = http.createServer(async (request, response) => {
          if (request.url !== '/v1/chat/completions' || request.method !== 'POST' || request.headers.authorization !== 'Bearer PUBLIC-FIXTURE-ONLY') {
            response.writeHead(400); response.end(); return;
          }
          const chunks = [];
          for await (const chunk of request) chunks.push(chunk);
          const body = JSON.parse(Buffer.concat(chunks));
          const messages = body.messages.map(row => row.content).filter(value => typeof value === 'string');
          const compact = messages.some(text => text.startsWith('用户要求原文（仅作为理解记录的依据，不必复述）：'));
          const markers = [...new Set(messages.flatMap(text => text.match(/PUBLIC_[A-Za-z0-9_]+/g) ?? []))];
          fs.appendFileSync(process.argv[3], JSON.stringify({kind: compact ? 'compact' : 'turn', markers}) + '\n');
          response.writeHead(200, {'Content-Type': 'application/json'});
          response.end(JSON.stringify({model: 'fixture-loopback', choices: [{message: {content: compact ? 'PUBLIC_COMPACT_SUMMARY_5193' : 'PUBLIC_REPLY_7008'}, finish_reason: 'stop'}], usage: {prompt_tokens: 500, completion_tokens: 20}}));
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(server.address().port)));
        """#
        try Data(serverScript.utf8).write(to: server)
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node"); fixture.arguments = [server.path, port.path, trace.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }
        let portDeadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: port.path), fixture.isRunning, Date() < portDeadline { await wait(0.025) }
        guard let number = Int(try String(contentsOf: port, encoding: .utf8)), (1...65_535).contains(number) else { throw PetError("本机协议样例未启动") }

        let hookScript = #"""
        #!/bin/sh
        IFS= read -r event
        case "$1" in
          startup|resume|fork|compact|clear|new)
            case "$event" in *'"model":"fixture-loopback"'*) ;; *) exit 11 ;; esac
            case "$event" in *'"hook_event_name":"SessionStart"'*'"source":"'"$1"'"'*) ;; *) exit 12 ;; esac
            if [ "$1" = compact ] && [ -f compact-halt ]; then printf '%s\n' '{"continue":false,"stopReason":"公开样例停止压缩后的续跑"}'; exit 0; fi
            printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"PUBLIC_HOOK_%s"}}\n' "$1" ;;
          pre)
            case "$event" in *'"custom_instructions":""'*'"hook_event_name":"PreCompact"'*'"trigger":"'"$2"'"'*'"turn_id":"'*'"'*) ;; *) exit 13 ;; esac
            if [ -f pre-deny ]; then printf '%s\n' '公开样例在压缩前拦截' >&2; exit 2; fi
            printf '{"systemMessage":"PUBLIC_BEFORE_%s"}\n' "$2" ;;
          post)
            case "$event" in *'"compact_summary":"PUBLIC_COMPACT_SUMMARY_5193"'*'"hook_event_name":"PostCompact"'*'"trigger":"'"$2"'"'*'"turn_id":"'*'"'*) ;; *) exit 14 ;; esac
            if [ -f post-halt ]; then printf '%s\n' '{"continue":false,"stopReason":"公开样例在压缩后暂停"}'; exit 0; fi
            printf '{"systemMessage":"PUBLIC_AFTER_%s"}\n' "$2" ;;
        esac
        """#
        try Data(hookScript.utf8).write(to: scripts.appendingPathComponent("lifecycle.sh"))
        func group(_ name: String, _ matcher: String, args: String) -> [String: Any] {
            ["matcher": "^" + matcher + "$", "hooks": [["name": name, "type": "command", "command": "/bin/sh \"$QODER_HOOK_ROOT/lifecycle.sh\" " + args, "timeout": 5]]]
        }
        let codexConfig = try JSONSerialization.data(withJSONObject: ["hooks": [
            "SessionStart": ["startup", "resume", "fork", "compact", "clear"].map { group("start-" + $0, $0, args: $0) },
            "PreCompact": ["manual", "auto"].map { group("before-" + $0, $0, args: "pre " + $0) },
            "PostCompact": ["manual", "auto"].map { group("after-" + $0, $0, args: "post " + $0) }
        ]], options: [.sortedKeys])
        try codexConfig.write(to: codex.appendingPathComponent("hooks.json"))
        let qoder = project.appendingPathComponent(".qoder"), qoderScripts = qoder.appendingPathComponent("hooks")
        try fm.createDirectory(at: qoderScripts, withIntermediateDirectories: true)
        try Data(hookScript.utf8).write(to: qoderScripts.appendingPathComponent("lifecycle.sh"))
        try JSONSerialization.data(withJSONObject: ["hooks": ["SessionStart": [group("start-new", "new", args: "new")]]])
            .write(to: qoder.appendingPathComponent("settings.json"))
        let keychain = PetKeychain(service: "com.xjs.bluefatfish.hook-lifecycle-check",
                                   configurationFile: output.appendingPathComponent("fixture-key.json"), migrateLegacy: false)
        try keychain.write("PUBLIC-FIXTURE-ONLY", account: "chat")
        let store = AgentStore(directory: profile, legacy: [], extensionHome: home)
        try store.organization.register(project.path, mode: .coding)
        let first = store.create(title: "公开会话验证", workspace: project.path, mode: .ask)
        _ = try await AgentGit(store: store, taskID: first, directory: AgentGit.metadata(workspace: project.path, creating: true)).initialize()
        await store.dataImport.detect(.codex, root: source, category: .configuration, workspace: project.path)
        guard let item = store.dataImport.preview.first(where: { $0.issue == nil }) else { throw PetError("本机会话 Hooks 无导入预览") }
        try await AgentStandaloneDataImport.install(item, root: source, store: store)
        let handlers = try store.hooks.catalog(workspace: project.path)
        checks["importedLifecycleHandlersStartDisabled"] = handlers.count == 10 && handlers.allSatisfy { !store.hooks.enabled($0) }
            && handlers.first(where: { $0.name == "start-new" })?.source == qoder.appendingPathComponent("settings.json").path
        for handler in handlers { try store.hooks.setEnabled(handler, true, workspace: project.path) }

        var admitted = 0
        func runtime(_ target: AgentStore) -> AgentRuntime {
            let runtime = AgentRuntime(store: target, keychain: keychain) {
                var p = PetPreferences(); p.model = "fixture-loopback"; p.contextTokens = 8192; p.replyTokens = 512
                p.endpoint = "http://127.0.0.1:\(number)/v1"; p.visionMode = "off"; return p
            }
            runtime.taskSettings = { var s = AgentGeneralSettings.Settings(); s.promptSuggestions = false; s.skillEvolutionSuggestions = false; return s }
            runtime.modelRequestCheck = { guard admitted < 18 else { throw PetError("本机协议验收请求上限") }; admitted += 1 }
            return runtime
        }
        func settle(_ runtime: AgentRuntime, _ id: String) async throws -> AgentTaskRecord {
            let deadline = Date().addingTimeInterval(15)
            while runtime.isBusy(id), Date() < deadline { await wait(0.025) }
            guard !runtime.isBusy(id), let task = runtime.store.task(id) else { runtime.cancel(id); throw PetError("本机流程未结束") }
            return task
        }
        func requests() throws -> [[String: Any]] {
            guard fm.fileExists(atPath: trace.path) else { return [] }
            return try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map { try AgentConfigurationJSON.object(Data($0.utf8)) }
        }
        func lastRequest(_ marker: String) throws -> Bool { ((try requests().last)?["markers"] as? [String])?.contains(marker) == true }
        func events(_ task: AgentTaskRecord) -> [String] { task.events.filter { $0.hook != nil && $0.status == "completed" }.map(\.title) }
        let originalRuntime = runtime(store)
        guard originalRuntime.submit("PUBLIC_INITIAL_TURN", taskID: first) else { throw PetError("初始任务未执行") }
        let original = try await settle(originalRuntime, first)
        checks["firstPromptStartsStartupBeforeRequest"] = try original.status == .completed && original.summary == reply
            && events(original) == ["start-startup"] && lastRequest("PUBLIC_HOOK_startup")
        let reopened = AgentStore(directory: profile, legacy: [], extensionHome: home), next = runtime(reopened)
        guard next.submit("PUBLIC_REOPENED_TURN", taskID: first) else { throw PetError("重开任务未继续") }
        let resumed = try await settle(next, first)
        checks["openingStoredTaskUsesResumeAndPreservesStartupHistory"] = try events(resumed) == ["start-startup", "start-resume"]
            && resumed.status == .completed && lastRequest("PUBLIC_HOOK_resume")
        guard let branch = reopened.fork(first) else { throw PetError(reopened.writeError ?? "分支未创建") }
        let branchStore = AgentStore(directory: profile, legacy: [], extensionHome: home), branchRuntime = runtime(branchStore)
        checks["forkSourceSurvivesRelaunchBeforeFirstUse"] = branchStore.task(branch)?.nextHookStartSource == .fork
        guard branchRuntime.submit("PUBLIC_BRANCH_TURN", taskID: branch) else { throw PetError("分支任务未执行") }
        let fork = try await settle(branchRuntime, branch)
        checks["actualBranchTaskUsesForkExactlyOnce"] = try events(fork) == ["start-startup", "start-resume", "start-fork"]
            && fork.status == .completed && lastRequest("PUBLIC_HOOK_fork") && branchStore.task(first)?.messages.map(\.id) == resumed.messages.map(\.id)

        let question = branchStore.create(title: "公开审批恢复", workspace: project.path)
        let ask = AgentToolCall(id: "fixture-question", name: "ask_user", arguments: #"{"question":"公开样例编号是多少？"}"#)
        branchStore.update(question) {
            $0.messages = [.init(role: "user", content: "PUBLIC_QUESTION"), .init(role: "assistant", content: "", toolCalls: [ask])]
            $0.pendingCalls = [ask]
        }
        branchRuntime.start(question)
        let waiting = try await settle(branchRuntime, question)
        let waitingCount = branchStore.tasks.count, waitingVersion = try branchStore.recordVersion(question)
        checks["clearCannotLeaveANonterminalApproval"] = try !branchRuntime.submit("/clear 仍有待确认", taskID: question)
            && !branchRuntime.submit("/new 仍有待确认", taskID: question) && branchStore.tasks.count == waitingCount
            && branchStore.recordVersion(question) == waitingVersion && branchStore.task(question)?.pendingCalls.map(\.id) == [ask.id]
        branchRuntime.decide(taskID: question, callID: ask.id, decision: "answer:PUBLIC_CONFIRMED_ANSWER")
        let answered = try await settle(branchRuntime, question)
        checks["approvalContinuationKeepsSessionWithoutReplayingStart"] = try waiting.status == .waiting && waiting.hookSession != nil
            && answered.status == .completed && events(answered) == events(waiting) && events(answered) == ["start-resume"]
            && lastRequest("PUBLIC_CONFIRMED_ANSWER")

        func seed(_ title: String, exchanges: Int) -> (String, [String]) {
            let id = branchStore.create(title: title, workspace: project.path, mode: .ask)
            let long = String(repeating: "Public harbor fixture readings and original report values. ", count: 65)
            var history = (0..<exchanges).flatMap { i in [AgentMessage(role: "user", content: "PUBLIC_HISTORY_\(i)"), AgentMessage(role: "assistant", content: long)] }
            history.append(AgentMessage(role: "user", content: "PUBLIC_LATEST_REQUIREMENT"))
            branchStore.update(id) { $0.messages = history; $0.status = .completed }
            return (id, history.map(\.id))
        }
        let (manual, originals) = seed("公开手动压缩", exchanges: 2)
        let deny = project.appendingPathComponent("pre-deny")
        try Data().write(to: deny)
        let before = try requests().count
        guard branchRuntime.submit("/compact", taskID: manual) else { throw PetError(branchRuntime.submissionError ?? "手动流程未启动") }
        let blocked = try await settle(branchRuntime, manual)
        checks["preCompactExitTwoBlocksWithoutSummaryRequest"] = try requests().count == before && blocked.contextThroughID == nil
            && blocked.messages.map(\.id) == originals && branchRuntime.analysisError(manual, recap: false)?.contains("公开样例在压缩前拦截") == true
            && blocked.events.contains { $0.title == "before-manual" && $0.status == "blocked" }
        try fm.moveItem(at: deny, to: project.appendingPathComponent("pre-permitted"))
        var sawDurableSummary = false
        branchRuntime.onChange = { id in
            guard branchStore.task(id)?.events.last?.hook?.event == .postCompact,
                  let data = try? Data(contentsOf: branchStore.directory.appendingPathComponent(id + ".json")),
                  let saved = try? JSONDecoder().decode(AgentTaskRecord.self, from: data), saved.contextSummary == summary,
                  saved.contextThroughID != nil else { return }
            sawDurableSummary = true
        }
        guard branchRuntime.submit("/compact", taskID: manual) else { throw PetError("再次手动压缩未启动") }
        let compacted = try await settle(branchRuntime, manual)
        checks["retryRunsPrePostAndCompactStartInOrder"] = events(compacted) == ["before-manual", "after-manual", "start-compact"]
            && sawDurableSummary && compacted.contextSummary == summary && compacted.contextManualThroughID != nil
        checks["manualCompactionPreservesFullOriginalMessages"] = compacted.messages.map(\.id) == originals && compacted.hookContexts?.values.contains("PUBLIC_HOOK_compact") == true
        guard branchRuntime.submit("PUBLIC_AFTER_MANUAL", taskID: manual) else { throw PetError("手动压缩后未继续") }
        _ = try await settle(branchRuntime, manual)
        checks["manualContextReachesNextActualRequest"] = try lastRequest("PUBLIC_HOOK_compact") && lastRequest("PUBLIC_LATEST_REQUIREMENT") && lastRequest(summary)

        let (automatic, autoOriginals) = seed("公开自动压缩", exchanges: 7)
        guard branchRuntime.submit("PUBLIC_AFTER_AUTOMATIC", taskID: automatic) else { throw PetError("自动压缩样例未启动") }
        let auto = try await settle(branchRuntime, automatic), autoEvents = events(auto)
        checks["autoCompactionMatchesAndDeliversWithinSameTurn"] = try auto.status == .completed && auto.contextSummary == summary
            && auto.contextManualThroughID == nil && autoEvents.contains("before-auto") && autoEvents.contains("after-auto")
            && autoEvents.contains("start-compact") && !autoEvents.contains("before-manual")
            && lastRequest("PUBLIC_AFTER_AUTOMATIC") && lastRequest("PUBLIC_HOOK_compact")
        checks["autoCompactionRetainsExistingHistory"] = Array(auto.messages.prefix(autoOriginals.count)).map(\.id) == autoOriginals

        let (halt, haltedOriginals) = seed("公开压缩后暂停", exchanges: 2)
        let post = project.appendingPathComponent("post-halt"); try Data().write(to: post)
        guard branchRuntime.submit("/compact", taskID: halt) else { throw PetError("压缩后暂停样例未启动") }
        let halted = try await settle(branchRuntime, halt)
        checks["postCompactCanStopAfterSavingWithoutDispatchingStart"] = halted.contextSummary == summary
            && halted.messages.map(\.id) == haltedOriginals && !events(halted).contains("start-compact")
            && halted.events.contains { $0.title == "after-manual" && $0.status == "blocked" }
            && branchRuntime.analysisError(halt, recap: false)?.contains("公开样例在压缩后暂停") == true
        try fm.moveItem(at: post, to: project.appendingPathComponent("post-permitted"))
        let (stop, _) = seed("公开压缩后停止续跑", exchanges: 7)
        let stopMarker = project.appendingPathComponent("compact-halt"); try Data().write(to: stopMarker)
        let beforeStop = try requests().count
        guard branchRuntime.submit("PUBLIC_BLOCKED_CONTINUATION", taskID: stop) else { throw PetError("自动压缩停止样例未启动") }
        let stopped = try await settle(branchRuntime, stop), stoppedRequests = try requests().dropFirst(beforeStop)
        checks["compactStartCanStopImmediateContinuation"] = stopped.status == .failed && stopped.contextSummary == summary
            && stopped.events.contains { $0.title == "start-compact" && $0.status == "blocked" }
            && stoppedRequests.count == 1 && stoppedRequests.first?["kind"] as? String == "compact"
        try fm.moveItem(at: stopMarker, to: project.appendingPathComponent("compact-permitted"))
        let (ui, _) = seed("公开压缩窗口验收", exchanges: 2)

        let attachmentFile = output.appendingPathComponent("public-previous-note.txt")
        try Data("PUBLIC_PREVIOUS_ATTACHMENT\n".utf8).write(to: attachmentFile)
        let attachment = try await AgentAttachments.importFile(attachmentFile, store: branchStore, taskID: first)
        branchStore.update(first) {
            $0.draft = "PUBLIC_PREVIOUS_DRAFT"; $0.draftAttachmentIDs = [attachment.id]; $0.contextSummary = "PUBLIC_PREVIOUS_SUMMARY"
            $0.permission = .review; $0.modelOverride = "fixture-loopback"
        }
        let originalVersion = try branchStore.recordVersion(first), requestsBeforeSessionCommands = try requests().count
        var opened: [String] = []
        guard branchRuntime.submit("/clear 公开清空会话", taskID: first, attachmentIDs: [attachment.id], onSessionOpened: { opened.append($0) }),
              branchRuntime.submit("/new 公开新会话", taskID: first, onSessionOpened: { opened.append($0) }), opened.count == 2 else {
            throw PetError(branchRuntime.submissionError ?? "会话命令未创建目标")
        }
        checks["sessionCommandsAreLocalAndPreserveOriginalTaskBytes"] = try requests().count == requestsBeforeSessionCommands
            && branchStore.recordVersion(first) == originalVersion && branchStore.selectedID == opened[1]
            && branchStore.slashMenu.recentIDs.prefix(2).elementsEqual(["builtin.new", "builtin.clear"])
            && Set(opened + [first]).count == 3
        let sessionStore = AgentStore(directory: profile, legacy: [], extensionHome: home), sessionRuntime = runtime(sessionStore)
        let originalNote = try AgentAttachments.source(store: sessionStore, taskID: first, id: attachment.id)
        checks["originalDialogueDraftAndAttachmentCanBeReopened"] = try sessionStore.recordVersion(first) == originalVersion
            && sessionStore.task(first)?.messages.map(\.id) == resumed.messages.map(\.id)
            && sessionStore.task(first)?.draft == "PUBLIC_PREVIOUS_DRAFT" && sessionStore.task(first)?.draftAttachmentIDs == [attachment.id]
            && Data(contentsOf: originalNote) == Data(contentsOf: attachmentFile)
        let expectations: [(AgentHookStartSource, String, String)] = [
            (.clear, "公开清空会话", "PUBLIC_FIRST_AFTER_CLEAR"), (.new, "公开新会话", "PUBLIC_FIRST_AFTER_NEW")
        ]
        for (id, expected) in zip(opened, expectations) {
            let (source, title, prompt) = expected
            let empty = sessionStore.task(id)
            checks["freshSessionPreservesScopeAndSourceAfterReload-" + source.rawValue] = empty?.pendingFreshSessionSource == source
                && empty?.nextHookStartSource == nil
                && empty?.title == title && empty?.workspace == project.path && empty?.mode == .ask && empty?.permission == .review
                && empty?.modelOverride == "fixture-loopback" && empty?.messages.isEmpty == true && empty?.events.isEmpty == true
                && empty?.attachments == nil && empty?.draft == nil && empty?.contextSummary == nil && empty?.modelReceipts == nil
                && empty?.parentID == nil && empty?.inputTokens == 0 && empty?.outputTokens == 0
            guard sessionRuntime.submit(prompt, taskID: id) else { throw PetError("空白会话的首次输入未执行") }
            let result = try await settle(sessionRuntime, id)
            let markers = (try requests().last)?["markers"] as? [String] ?? []
            checks["sourceHookReadsFirstNewTurnWithoutPriorContext-" + source.rawValue] = result.status == .completed
                && events(result) == ["start-" + source.rawValue] && markers.contains(prompt) && markers.contains("PUBLIC_HOOK_" + source.rawValue)
                && !markers.contains("PUBLIC_INITIAL_TURN") && !markers.contains("PUBLIC_REOPENED_TURN") && !markers.contains("PUBLIC_PREVIOUS_SUMMARY")
                && !markers.contains("PUBLIC_HOOK_startup") && result.nextHookStartSource == .resume && result.pendingFreshSessionSource == nil
        }
        guard sessionRuntime.submit("PUBLIC_AFTER_FRESH_SESSION", taskID: opened[0]) else { throw PetError("已执行的新会话未继续") }
        let continued = try await settle(sessionRuntime, opened[0])
        checks["subsequentTurnUsesResumeWithoutReplayingClear"] = try events(continued) == ["start-clear", "start-resume"]
            && lastRequest("PUBLIC_HOOK_resume") && continued.status == .completed
        let general = sessionStore.create(title: "无工作区旧会话", mode: .ask, workMode: .general)
        sessionStore.update(general) { $0.messages = [.init(role: "user", content: "公开原记录")]; $0.status = .completed }
        let count = sessionStore.tasks.count
        checks["noWorkspaceSupportsNewAndRejectsInvalidTitle"] = !sessionRuntime.submit("/clear " + String(repeating: "字", count: 121), taskID: general)
            && sessionStore.tasks.count == count && sessionRuntime.submit("/new", taskID: general)
            && sessionStore.selected?.pendingFreshSessionSource == .new && sessionStore.selected?.workspace == nil
            && sessionStore.selected?.organizationMode == .general && sessionStore.selected?.messages.isEmpty == true
        sessionStore.selectedID = ui
        let received = try requests()
        checks["allFixtureTrafficIsLocalAndAccountedFor"] = received.count == admitted && received.contains { $0["kind"] as? String == "compact" }
        try JSONSerialization.data(withJSONObject: ["taskID": ui, "loopbackRequests": received.count], options: [.sortedKeys]).write(
            to: output.appendingPathComponent("hook-lifecycle-fixture.json"), options: .atomic)
    }

    func prepareFreshSessionWindow(_ output: URL, tasks: AgentStore) throws {
        let project = output.appendingPathComponent("SessionWindow")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try tasks.organization.register(project.path, mode: .coding)
        let id = tasks.create(title: "公开原会话", workspace: project.path, mode: .ask)
        let history = [AgentMessage(role: "user", content: "公开原会话的可恢复正文"),
                       AgentMessage(role: "assistant", content: "公开原会话的历史答复")]
        tasks.update(id) { $0.messages = history; $0.status = .completed; $0.permission = .review }
        let groups = try ["clear", "new"].map { source -> [String: Any] in
            let output = try JSONSerialization.data(withJSONObject: ["continue": false, "stopReason": "公开样例已记录 " + source + " 来源"])
            return ["matcher": "^" + source + "$", "hooks": [["name": "公开会话来源 " + source, "type": "command", "command": "/usr/bin/printf",
                    "args": ["%s", String(decoding: output, as: UTF8.self)]]]]
        }
        let config = try JSONSerialization.data(withJSONObject: ["hooks": ["SessionStart": groups]], options: [.sortedKeys])
        try tasks.hooks.save(String(decoding: config, as: UTF8.self), project: true, workspace: project.path, expectedHash: nil)
        for handler in try tasks.hooks.catalog(workspace: project.path) where handler.name.hasPrefix("公开会话来源 ") {
            try tasks.hooks.setEnabled(handler, true, workspace: project.path)
        }
        let proof = ["taskID": id, "workspace": project.path, "messageIDs": history.map(\.id).joined(separator: ",")]
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]).write(
            to: output.appendingPathComponent("fresh-session-window-fixture.json"), options: .atomic)
        control.showAgentTask(id)
    }
}
