import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentProjectChangesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], review: AgentGitWindow?
        let fm = FileManager.default, repo = output.appendingPathComponent("repo")
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(args)) }
        func write(_ value: [String: Any], _ name: String) throws { try Data(json(value).utf8).write(to: output.appendingPathComponent(name), options: .atomic) }
        func until(_ seconds: Double, _ predicate: () throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if try predicate() { return true }; await wait(0.05) }; return try predicate()
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": ProcessInfo.processInfo.processIdentifier, "arguments": CommandLine.arguments], "check-process.json")
            if CommandLine.arguments.contains("--file-change-ui-only") {
                do {
                    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("file-change-report.json"))) as! [String: Any]
                    guard previous["success"] as? Bool == true, let ui = previous["ui"] as? [String: Any], let id = ui["taskID"] as? String, let task = tasks.task(id), task.status == .completed else { throw PetError("已完成的真实文件验收任务不存在") }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let usage = try encoder.encode(task.modelReceipts ?? [])
                    control.showAgentTask(id); control.show(tab: "chat")
                    review = AgentGitWindow(store: tasks, taskID: id) { [weak self] in self?.control.showAgentTask($0) }
                    review?.showWindow(nil); review?.window?.makeKeyAndOrderFront(nil)
                    try write(["appPID": ProcessInfo.processInfo.processIdentifier, "taskID": id, "requestCount": task.modelReceipts?.count ?? 0, "receiptSHA256": AgentFiles.hash(usage)], "file-change-ui-ready.json")
                    let deadline = Date().addingTimeInterval(1200)
                    while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui-only").path) { await wait(0.25) }
                    let unchanged = try encoder.encode(tasks.task(id)?.modelReceipts ?? []) == usage
                    try write(["success": unchanged && fm.fileExists(atPath: output.appendingPathComponent("finish-ui-only").path), "taskID": id, "modelRequestsUnchanged": unchanged], "file-change-ui-result.json")
                } catch { try? write(["success": false, "error": error.localizedDescription], "file-change-ui-result.json") }
                return
            }
            let files = try AgentFiles(workspace: repo.path)
            if CommandLine.arguments.contains("--capture-interrupt") {
                let id = tasks.create(title: "实际中断的文件命令", workspace: repo.path)
                tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "写入公开中断标记后等待")); $0.status = .running }
                try write(["appPID": ProcessInfo.processInfo.processIdentifier, "taskID": id], "interruption-owner.json")
                _ = try await AgentTools(store: tasks, taskID: id).execute(call("run_command", ["command": "printf 'written-before-kill\\n' > interrupt.txt\nprintf '%s\\n' \"$$\" > interruption-process.pid\n/bin/sleep 30", "timeout_seconds": 40]))
                throw PetError("中断验收未终止实际应用进程")
            }
            if CommandLine.arguments.contains("--capture-recover") {
                let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("interruption-owner.json"))) as! [String: Any]
                guard let id = owner["taskID"] as? String, let task = tasks.task(id), let warning = task.gitTurn?.warning else { throw PetError("实际中断后的任务未恢复为待核对状态") }
                let event = task.events.first { $0.title == "变更记录中断" }
                let manifests = try fm.contentsOfDirectory(at: tasks.backupDirectory(id).appendingPathComponent("captures"), includingPropertiesForKeys: nil)
                guard let manifest = manifests.first else { throw PetError("实际执行前快照缺失") }
                let values = try JSONDecoder().decode([String: AgentCapturedFile].self, from: Data(contentsOf: manifest))
                let previous = values[try files.literalURL("interrupt.txt").path]
                let recovered = task.status == .stopped && task.pendingFileCapture == nil && task.changes.isEmpty && event != nil && !warning.isEmpty && previous?.state.hash == AgentFiles.hash(Data("original-before-interrupt\n".utf8))
                let current = try files.readData(files.resolve("interrupt.txt"))
                try write(["success": recovered && current == Data("written-before-kill\n".utf8), "taskID": id, "recoveryAppPID": ProcessInfo.processInfo.processIdentifier, "beforeManifest": manifest.path, "originalBackupHash": previous?.state.hash ?? "", "currentHash": AgentFiles.hash(current), "replayed": false], "interruption-report.json")
                return
            }
            func git(_ args: [String]) async throws -> String {
                let scratch = output.appendingPathComponent("tmp"); try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: repo, scratch: scratch, network: false, timeout: 15, readOnly: true, gitDirectory: repo.appendingPathComponent(".git"), protectedData: store.directory, arguments: args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            func finishLive(existingID: String? = nil, server: AgentMCPServer, noteBefore: Data) async throws -> String {
                let note = repo.appendingPathComponent("mcp-note.json")
                var p = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                let liveID = existingID ?? tasks.create(title: "实际销售核对与 MCP 备注", workspace: repo.path)
                tasks.update(liveID) { $0.permission = .review }
                if existingID != nil {
                    _ = try await tasks.mcp.connect(server.id, revision: server.revision, owner: liveID, workspace: repo.path)
                    guard let connection = tasks.mcp.token(server.id, owner: liveID) else { throw PetError("原已批准的官方文件服务未重新连接") }
                    let read = try tasks.mcp.catalog(server.id, owner: liveID, token: connection, offset: 0, query: "read_text_file"), write = try tasks.mcp.catalog(server.id, owner: liveID, token: connection, offset: 0, query: "write_file")
                    let names = Set(try runtime.toolDefinitions(tasks.task(liveID)!, preferences: p).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                    let expected = [read, write].compactMap { ($0["tools"] as? [[String: Any]])?.first?["model_tool"] as? String }
                    checks["actualModelDefinitionsKeepOfficialReadAndWriteAvailableAtSavedBudget"] = expected.count == 2 && Set(expected).isSubset(of: names)
                    guard checks["actualModelDefinitionsKeepOfficialReadAndWriteAvailableAtSavedBudget"] == true else { throw PetError("真实 API 工具定义缺少读取或写入函数") }
                }
                let prompt = "核对当前项目sales.csv的销售合计和数据行数。通过run_command实际计算并写terminal-report.json，只含total和rows两个数字字段。然后通过已配置的‘实际项目文件服务’MCP读取该报告，再覆盖mcp-note.json，只含total、rows、reviewer三个字段，reviewer为海盐-7319。回读两份结果后报告。终端只执行计算和这份报告写入，不创建脚本，不用原生write_file/edit_file代写报告，不访问网络、不提交推送、不修改任何输入。"
                if existingID != nil { runtime.start(liveID) }
                else { guard runtime.submit(prompt, taskID: liveID) else { throw PetError("真实模型任务未开始") } }
                var approvals = 0; var routes: [String: [String: Any]] = [:]; var rejected: [String] = []
                guard try await until(240, {
                    guard let current = tasks.task(liveID) else { throw PetError("真实任务不存在") }
                    if current.status == .waiting, let action = current.pendingCalls.first {
                        let scoped = try tasks.mcp.routedCall(action, owner: liveID) ?? action
                        if ["write_file", "edit_file"].contains(scoped.name) {
                            guard rejected.count < 3 else { throw PetError("真实模型反复请求绕过 MCP 的写入") }
                            runtime.decide(taskID: liveID, callID: action.id, decision: "deny"); rejected.append(action.id); return false
                        }
                        guard approvals < 14, ["run_command", "connect_mcp", "call_mcp_tool"].contains(scoped.name) else { throw PetError("真实任务提出了预期外审批：" + scoped.name) }
                        if scoped.name == "run_command" {
                            let command = scoped.object["command"] as? String ?? ""
                            let readback = command.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^(?:/bin/)?cat\s+(?:terminal-report\.json|mcp-note\.json)(?:\s+(?:terminal-report\.json|mcp-note\.json))?$"#, options: .regularExpression) != nil
                            let calculation = command.contains("sales.csv") && command.contains("terminal-report.json") && ![".env", "rm ", "git ", "curl ", "mcp-note"].contains(where: command.contains)
                            if scoped.object["network"] as? Bool == true || !(readback || calculation) {
                                guard rejected.count < 3 else { throw PetError("真实模型反复请求范围外命令") }
                                runtime.decide(taskID: liveID, callID: action.id, decision: "deny"); rejected.append(action.id); return false
                            }
                        } else if scoped.name == "connect_mcp" { guard scoped.object["server_id"] as? String == server.id else { throw PetError("真实任务试图连接其他服务") } }
                        else {
                            let args = scoped.object["arguments"] as? [String: Any] ?? [:], path = args["path"] as? String ?? "", tool = scoped.object["tool"] as? String ?? ""
                            let paths = tool == "read_multiple_files" ? args["paths"] as? [String] ?? [] : [path]
                            let targets = try paths.map { try files.literalURL($0) }
                            guard scoped.object["server_id"] as? String == server.id, ["read_text_file", "read_file", "read_multiple_files", "get_file_info", "write_file"].contains(tool), !targets.isEmpty, targets.count <= 3, targets.allSatisfy({ ["sales.csv", "terminal-report.json", "mcp-note.json"].contains($0.lastPathComponent) && $0.deletingLastPathComponent() == files.root }), tool != "write_file" || targets.map(\.lastPathComponent) == ["mcp-note.json"] else { throw PetError("真实任务提出了范围外 MCP 写入") }
                        }
                        if scoped.name == "call_mcp_tool" { routes[action.id] = ["function": action.name, "server_id": server.id, "tool": scoped.object["tool"] ?? "", "arguments": scoped.object["arguments"] ?? [:]] }
                        runtime.decide(taskID: liveID, callID: action.id, decision: "allow"); approvals += 1
                    }
                    if [.failed, .stopped].contains(current.status), !runtime.isExecuting(liveID) { throw PetError("真实模型任务未完成：" + (current.events.last?.detail ?? "")) }
                    return current.status == .completed && !runtime.isExecuting(liveID)
                }) else { runtime.cancel(liveID); throw PetError("真实模型任务超时") }
                let live = tasks.task(liveID)!, terminalData = try Data(contentsOf: repo.appendingPathComponent("terminal-report.json")), noteData = try Data(contentsOf: note)
                let terminal = try JSONSerialization.jsonObject(with: terminalData) as! [String: Any], actualNote = try JSONSerialization.jsonObject(with: noteData) as! [String: Any]
                checks["realModelTerminalAndMcpOutputsMatchActualCsv"] = terminal.count == 2 && (terminal["total"] as? NSNumber)?.doubleValue == 49 && (terminal["rows"] as? NSNumber)?.intValue == 3 && actualNote.count == 3 && (actualNote["total"] as? NSNumber)?.doubleValue == 49 && (actualNote["rows"] as? NSNumber)?.intValue == 3 && actualNote["reviewer"] as? String == "海盐-7319"
                checks["realModelBothToolKindsHaveActualLastTurnCheckpoints"] = Set(live.gitTurn?.changes.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? []) == ["terminal-report.json", "mcp-note.json"] && live.changes.contains { $0.path == note.path && $0.origin == "MCP 工具" && $0.beforeHash == AgentFiles.hash(noteBefore) } && live.changes.contains { $0.path.hasSuffix("/terminal-report.json") && $0.origin == "命令" && $0.beforeState.kind == "missing" }
                checks["realModelDoesNotBypassTerminalOrMcpWithNativeWrites"] = !live.events.contains { ["write_file", "edit_file"].contains($0.title) && $0.status == "completed" }
                checks["outOfScopeRequestsActuallyReceiveRejection"] = rejected.allSatisfy { callID in live.approvals.contains { $0.call.id == callID && $0.decision == "deny" } && live.events.contains { $0.toolCallID == callID && $0.status == "failed" } }
                report["live"] = ["taskID": liveID, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "inputTokens": live.inputTokens, "outputTokens": live.outputTokens, "approvals": live.approvals.filter { $0.decision == "allow" }.count, "newApprovals": approvals, "rejectedCalls": rejected, "toolRoutes": routes, "permission": live.permission.rawValue, "terminalSHA256": AgentFiles.hash(terminalData), "mcpNoteSHA256": AgentFiles.hash(noteData)]
                return liveID
            }
            func publish(uiID: String, noteBefore: Data, index: Data, head: String) async throws {
                let note = repo.appendingPathComponent("mcp-note.json")
                let uiTask = tasks.task(uiID)!, uiChange = uiTask.changes.last { $0.path == note.path }!
                let finalHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
                checks["finalMainHeadAndRawIndexRemainExact"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == index && finalHead == head
                report["ui"] = ["taskID": uiID, "changeID": uiChange.id, "notePath": note.path, "beforeSHA256": AgentFiles.hash(noteBefore), "afterSHA256": uiChange.afterHash ?? ""]
                report["mainHead"] = head; report["mainIndexSHA256"] = AgentFiles.hash(index)
                report["appPID"] = ProcessInfo.processInfo.processIdentifier
                report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks
                try write(report, "file-change-report.json")
                if CommandLine.arguments.contains("--hold-ui"), checks.values.allSatisfy({ $0 }) {
                    control.showAgentTask(uiID); control.show(tab: "chat"); review = AgentGitWindow(store: tasks, taskID: uiID) { [weak self] in self?.control.showAgentTask($0) }; review?.showWindow(nil); review?.window?.makeKeyAndOrderFront(nil)
                    let deadline = Date().addingTimeInterval(1200)
                    while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
                }
                tasks.mcp.disconnect(); runtime.stopAll()
            }
            if CommandLine.arguments.contains("--resume-file-change-check") {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("original-verifier-report.json"))) as! [String: Any]
                guard let priorChecks = previous["checks"] as? [String: Bool], !priorChecks.isEmpty, priorChecks.values.allSatisfy({ $0 }) else { throw PetError("原始文件验收尚未通过，不能跳过") }
                checks = priorChecks
                guard let record = tasks.tasks.first(where: { $0.title == "实际销售核对与 MCP 备注" }), let pending = tasks.task(record.id), pending.status == .waiting, !pending.pendingCalls.isEmpty,
                      let connect = pending.approvals.first(where: { $0.call.name == "connect_mcp" && $0.decision == "allow" }), let serverID = connect.call.object["server_id"] as? String,
                      let original = tasks.tasks.first(where: { $0.title == "官方 MCP 实际文件变更" }), let change = tasks.task(original.id)?.changes.first(where: { $0.path.hasSuffix("/mcp-note.json") }), let backup = change.backup else { throw PetError("原始真实模型任务或原备注检查点不存在") }
                let backupFiles = try AgentFiles(workspace: tasks.backupDirectory(original.id).path), noteBefore = try backupFiles.readData(backupFiles.literalURL(backup))
                guard AgentFiles.hash(noteBefore) == change.beforeHash, try Data(contentsOf: repo.appendingPathComponent("mcp-note.json")) == noteBefore else { throw PetError("原备注在续验前发生了变化") }
                let originalIntent = pending.messages.last(where: \.isHumanInput)?.id, originalReceipts = pending.modelReceipts ?? []
                let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
                let uiID = try await finishLive(existingID: pending.id, server: tasks.mcp.server(serverID), noteBefore: noteBefore)
                let finished = tasks.task(uiID)!
                let receiptEncoder = JSONEncoder(); receiptEncoder.outputFormatting = [.sortedKeys]
                let previousReceipts = try receiptEncoder.encode(originalReceipts), currentReceipts = try receiptEncoder.encode(Array((finished.modelReceipts ?? []).prefix(originalReceipts.count)))
                checks["sameActualModelTaskResumesWithoutReplacingOriginalIntentOrReceipts"] = finished.id == pending.id && finished.messages.last(where: \.isHumanInput)?.id == originalIntent && (finished.modelReceipts?.count ?? 0) >= originalReceipts.count && previousReceipts == currentReceipts
                report["originalVerifierFailure"] = previous["error"] ?? ""; report["resumedExistingTask"] = true
                try await publish(uiID: uiID, noteBefore: noteBefore, index: index, head: head)
                return
            }
            let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            let original = try fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".git" }
            var originals: [String: AgentFileState] = [:]
            for url in original { originals[url.lastPathComponent] = try AgentCapturedFile.read(url.path, files: files, backups: nil).state }
            let id = tasks.create(title: "命令实际文件变更", workspace: repo.path), tools = AgentTools(store: tasks, taskID: id)
            tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "审阅实际命令产生的文件变更")) }
            let command = "printf 'agent-working\\n' > public.txt\n/bin/rm -- remove.txt\n/bin/mv -- rename.txt renamed.txt\nprintf 'created-by-command\\n' > new.txt\nprintf '\\001\\002\\003' >> binary.bin\nprintf '#!/bin/sh\\nprintf changed\\n' > executable.sh\n/bin/chmod 644 executable.sh\n/bin/chmod 755 mode-only.sh\n/bin/rm -- external-link\n/bin/ln -s public.txt external-link\n/bin/rm -- kind-change\n/bin/ln -s public.txt kind-change\nexit 7"
            let failed = try await tools.execute(call("run_command", ["command": command]))
            guard let task = tasks.task(id), let turn = task.gitTurn else { throw PetError("实际命令未产生文件变更记录") }
            let names = Set(turn.changes.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            checks["failedRealCommandStillCapturesAllActualFileChanges"] = failed.failed && names == ["public.txt", "remove.txt", "rename.txt", "renamed.txt", "new.txt", "binary.bin", "executable.sh", "mode-only.sh", "external-link", "kind-change"] && task.pendingFileCapture == nil
            checks["preexistingDirtyFileUsesActualBeforeNotHeadOrIndex"] = turn.changes.first { $0.path.hasSuffix("/public.txt") }?.beforeHash == originals["public.txt"]?.hash && originals["public.txt"]?.hash == AgentFiles.hash(Data("user-working\n".utf8))
            checks["deletionAndRenameSidesHaveExplicitMissingStates"] = turn.changes.first { $0.path.hasSuffix("/remove.txt") }?.afterState?.kind == "missing" && turn.changes.first { $0.path.hasSuffix("/rename.txt") }?.afterState?.kind == "missing" && turn.changes.first { $0.path.hasSuffix("/renamed.txt") }?.beforeState.kind == "missing"
            checks["unrelatedDirtyIgnoredAndProtectedFilesAreNotAttributed"] = !names.contains("user-only.txt") && !names.contains("ignored.txt") && !names.contains(".env")
            let objectNames = Set(try fm.contentsOfDirectory(atPath: tasks.backupDirectory(id).appendingPathComponent("objects").path))
            checks["automaticSnapshotsExcludeProtectedIgnoredAndExternalTargetBytes"] = !["public-protected-not-a-credential\n", "public-ignored-build-marker\n", "public-outside-never-read-marker\n"].contains { objectNames.contains(AgentFiles.hash(Data($0.utf8))) }
            let helper = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: repo.path))
            let text = try await helper.inspect(source: .lastTurn, revision: "", requested: ["public.txt"])
            let deleted = try await helper.inspect(source: .lastTurn, revision: "", requested: ["remove.txt"]), added = try await helper.inspect(source: .lastTurn, revision: "", requested: ["new.txt"])
            let binary = try await helper.inspect(source: .lastTurn, revision: "", requested: ["binary.bin"]), mode = try await helper.inspect(source: .lastTurn, revision: "", requested: ["mode-only.sh"])
            let link = try await helper.inspect(source: .lastTurn, revision: "", requested: ["external-link"])
            let type = try await helper.inspect(source: .lastTurn, revision: "", requested: ["kind-change"])
            checks["lastTurnDiffComparesActualCommandBaseline"] = text.diff.contains("-user-working") && text.diff.contains("+agent-working") && !text.diff.contains("-staged-public")
            checks["lastTurnIncludesActualAddedAndDeletedFilePatches"] = deleted.diff.contains("deleted file mode") && added.diff.contains("new file mode")
            checks["largeBinaryAndModeOnlyChangesAreReviewable"] = binary.binaryFiles == 1 && binary.diff.contains("GIT binary patch") && mode.diff.contains("old mode 100644") && mode.diff.contains("new mode 100755")
            checks["symlinkReviewReadsLinkTextWithoutOutsideTarget"] = link.diff.contains("public.txt") && !link.diff.contains("public-outside-never-read-marker")
            checks["actualFileToLinkTypeChangeHasBothLabeledPatches"] = type.diff.contains("deleted file mode 100644") && type.diff.contains("new file mode 120000") && type.diff.components(separatedBy: "diff --git a/kind-change b/kind-change").count == 3 && !type.diff.contains("compare-")
            for change in task.changes { try AgentChanges.restore(change, taskID: id, store: tasks) }
            checks["realRollbackRestoresExactLargeFilesPermissionsLinksAndDeletions"] = try originals.allSatisfy { name, state in try state == AgentCapturedFile.read(files.literalURL(name).path, files: files, backups: nil).state } && !fm.fileExists(atPath: repo.appendingPathComponent("new.txt").path) && !fm.fileExists(atPath: repo.appendingPathComponent("renamed.txt").path)
            let afterRollbackHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["rawGitIndexAndHeadRemainExactAfterCaptureAndRollback"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == index && afterRollbackHead == head
            tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "第二轮文件修改")) }
            _ = try await tools.execute(call("run_command", ["command": "printf 'first-agent-segment\\n' > public.txt"]))
            let previous = tasks.task(id)!.changes.last { $0.path.hasSuffix("/public.txt") }!
            try Data("user-between-commands\n".utf8).write(to: repo.appendingPathComponent("public.txt"))
            _ = try await tools.execute(call("run_command", ["command": "printf 'second-agent-segment\\n' >> public.txt"]))
            let latest = tasks.task(id)!.changes.last { $0.path.hasSuffix("/public.txt") }!
            checks["actualExternalEditStartsNewCheckpointSegment"] = latest.id != previous.id && latest.beforeHash == AgentFiles.hash(Data("user-between-commands\n".utf8)) && tasks.task(id)?.gitTurn?.changes.first?.beforeHash == latest.beforeHash
            try AgentChanges.restore(latest, taskID: id, store: tasks)
            checks["rollbackPreservesActualUserEditBetweenCommands"] = try files.readData(files.resolve("public.txt")) == Data("user-between-commands\n".utf8)
            do { try AgentChanges.restore(previous, taskID: id, store: tasks); checks["oldSegmentCannotOverwriteUserVersion"] = false } catch { checks["oldSegmentCannotOverwriteUserVersion"] = true }
            _ = try await tools.execute(call("write_file", ["path": "public.txt", "content": "native-file-tool\n"]))
            let direct = tasks.task(id)!.changes.last { $0.path.hasSuffix("/public.txt") }!
            checks["fileToolsShareSameActualCheckpointBoundary"] = direct.beforeHash == AgentFiles.hash(Data("user-between-commands\n".utf8)) && direct.afterKind == "file"
            try AgentChanges.restore(direct, taskID: id, store: tasks)
            let cancelID = tasks.create(title: "实际停止的文件命令", workspace: repo.path), cancelTools = AgentTools(store: tasks, taskID: cancelID)
            let cancelled = Task { try await cancelTools.execute(call("run_command", ["command": "printf 'partial-before-stop\\n' > cancel.txt\nprintf '%s\\n' \"$$\" > cancel-process.pid\n/bin/sleep 30", "timeout_seconds": 40])) }
            guard try await until(5, { (try? String(contentsOf: repo.appendingPathComponent("cancel-process.pid"), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil }) else { throw PetError("实际停止命令未开始") }
            let cancelledPID = pid_t(Int(try String(contentsOf: repo.appendingPathComponent("cancel-process.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)
            cancelled.cancel(); cancelTools.cancel(); tasks.update(cancelID) { $0.status = .stopped }
            do { _ = try await cancelled.value } catch {}
            checks["stoppedRealCommandKeepsActualPartialFileCheckpoint"] = tasks.task(cancelID)?.pendingFileCapture == nil && tasks.task(cancelID)?.changes.contains { $0.path.hasSuffix("/cancel.txt") && $0.afterHash == AgentFiles.hash(Data("partial-before-stop\n".utf8)) } == true
            checks["stoppingActuallyTerminatesOwnedProcess"] = try await until(3, { kill(cancelledPID, 0) != 0 })
            let timeoutID = tasks.create(title: "实际超时的文件命令", workspace: repo.path)
            let timed = try await AgentTools(store: tasks, taskID: timeoutID).execute(call("run_command", ["command": "printf 'partial-before-timeout\\n' > timeout.txt\n/bin/sleep 3", "timeout_seconds": 1]))
            checks["timedOutRealCommandRetainsActualPartialChanges"] = timed.failed && timed.timedOut == true && tasks.task(timeoutID)?.changes.contains { $0.path.hasSuffix("/timeout.txt") } == true
            let firstID = tasks.create(title: "实际并行命令一", workspace: repo.path), secondID = tasks.create(title: "实际并行命令二", workspace: repo.path)
            let first = Task { try await AgentTools(store: tasks, taskID: firstID).execute(call("run_command", ["command": "printf 'first\\n' > parallel.txt\n/bin/sleep 2"])) }
            guard try await until(5, { fm.fileExists(atPath: repo.appendingPathComponent("parallel.txt").path) }) else { throw PetError("实际并行命令未开始") }
            _ = try await AgentTools(store: tasks, taskID: secondID).execute(call("run_command", ["command": "printf 'second\\n' > parallel.txt"]))
            _ = try await first.value
            let parallel = tasks.task(secondID)!.changes.first { $0.path.hasSuffix("/parallel.txt") }!
            checks["overlappingRealTasksDoNotClaimExclusiveOwnership"] = parallel.reviewOnly == true && tasks.task(firstID)?.changes.contains { $0.path.hasSuffix("/parallel.txt") && $0.reviewOnly == true } == true
            do { try AgentChanges.restore(parallel, taskID: secondID, store: tasks); checks["parallelChangesCannotAutomaticallyOverwriteFiles"] = false } catch { checks["parallelChangesCannotAutomaticallyOverwriteFiles"] = true }
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as! [String: String]
            guard let node = fixtures["node"], let serverEntry = fixtures["serverEntry"] else { throw PetError("现有官方文件服务不可用") }
            let server = try tasks.mcp.save(json(["name": "实际项目文件服务", "type": "stdio", "command": node, "args": [serverEntry, repo.path], "env": [:], "timeoutSeconds": 20]))
            let mcpID = tasks.create(title: "官方 MCP 实际文件变更", workspace: repo.path), mcpTools = AgentTools(store: tasks, taskID: mcpID)
            tasks.update(mcpID) { $0.messages.append(AgentMessage(role: "user", content: "通过官方文件服务保存公开备注")) }
            _ = try await mcpTools.execute(call("connect_mcp", ["server_id": server.id, "configuration": server.revision]))
            guard let token = tasks.mcp.token(server.id, owner: mcpID), let serverPID = await tasks.mcp.processID(server.id, owner: mcpID) else { throw PetError("官方文件服务未实际连接") }
            _ = try tasks.mcp.catalog(server.id, owner: mcpID, token: token, offset: 0, query: "write_file")
            let note = repo.appendingPathComponent("mcp-note.json"), noteBefore = try Data(contentsOf: note)
            let noteAfter = try json(["total": 49, "rows": 3, "reviewer": "海盐-7319"])
            let external = try await mcpTools.execute(call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "write_file", "arguments": ["path": note.path, "content": noteAfter]]))
            let mcpChange = tasks.task(mcpID)!.changes.first { $0.path == note.path }!
            checks["officialMcpProcessWritesActualFileAndCheckpoint"] = !external.failed && kill(serverPID, 0) == 0 && mcpChange.beforeHash == AgentFiles.hash(noteBefore) && mcpChange.afterHash == AgentFiles.hash(Data(noteAfter.utf8)) && mcpChange.origin == "MCP 工具"
            checks["officialMcpChangesAppearInLastTurn"] = try await AgentGit(store: tasks, taskID: mcpID, directory: AgentGit.metadata(workspace: repo.path)).inspectionChanges(source: .lastTurn, revision: "").map(\.path) == ["mcp-note.json"]
            tasks.mcp.disconnect(owner: mcpID)
            let recovered = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("interruption-report.json"))) as! [String: Any]
            checks["actualKilledAppRecoversUncertainChangesWithoutReplay"] = recovered["success"] as? Bool == true
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("真实文件变更检查未通过") }
            var uiID = mcpID
            if CommandLine.arguments.contains("--live-agent") {
                try AgentChanges.restore(mcpChange, taskID: mcpID, store: tasks)
                uiID = try await finishLive(server: server, noteBefore: noteBefore)
            }
            try await publish(uiID: uiID, noteBefore: noteBefore, index: index, head: head)
        } catch {
            agentRuntime?.stopAll(); agentStore?.mcp.disconnect()
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? write(report, "file-change-report.json")
        }
    }
}
