import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentRuleCheck(_ output: URL) async {
        let fm = FileManager.default; var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        func waitUntil(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while !test() && Date() < end { await wait(0.03) }; return test() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("用户和项目规则原生检查禁止模型请求") }
            let rules = tasks.rules, project = output.appendingPathComponent("real project"), sourceURL = project.appendingPathComponent("src/deep/api.ts")
            let source = try Data(contentsOf: sourceURL)
            let id = tasks.create(title: "用户和项目规则实际读取", workspace: project.path, mode: .ask, workMode: .general)
            let other = tasks.create(title: "规则隔离任务", workspace: project.path, mode: .ask, workMode: .general)
            let global = tasks.create(title: "无工作区规则", mode: .ask, workMode: .general)
            func task(_ id: String) -> AgentTaskRecord { tasks.task(id)! }
            func context(_ id: String) throws -> String { try runtime.systemContext(task(id)) }
            func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)) }
            func make(_ name: String, _ trigger: AgentRuleTrigger, _ body: String, project: Bool = true, patterns: [String] = [], description: String = "") throws -> AgentLocalRuleItem {
                try rules.create(name: name, text: AgentRuleDocument.text(name: name, trigger: trigger, description: description, patterns: patterns, body: body), project: project, task: task(id))
            }
            let user = try make("user-review", .always, "USER_ALWAYS_923", project: false)
            _ = try make("project-review", .always, "PROJECT_ALWAYS_724")
            let manual = try make("manual-review", .manual, "LOCAL_MANUAL_625")
            let decision = try make("decision-review", .decision, "LOCAL_DECISION_BODY_526", description: "核对公开 README 中的项目元信息")
            _ = try make("source-review", .glob, "LOCAL_GLOB_427", patterns: ["src/**/*.ts", "!src/vendor/**"])
            _ = try make("user-source", .glob, "USER_GLOB_328", project: false, patterns: ["src/**/*.ts"])
            _ = try make("write-review", .glob, "ACTUAL_WRITE_GLOB_229", patterns: ["generated/*.txt"])
            _ = try make("edit-review", .glob, "ACTUAL_EDIT_GLOB_130", patterns: ["edit/*.md"])
            checks["nativeUserAndProjectRulesWrittenToSeparateRoots"] = user.source.path.hasPrefix(store.directory.path + "/extensions/rules/") && manual.source.path.hasPrefix(project.path + "/.bluefatfish/rules/")
            let initial = try context(id), withoutWorkspace = try context(global)
            checks["globalRulesWorkWithoutWorkspaceAndExcludeProjectRules"] = withoutWorkspace.contains("USER_ALWAYS_923") && withoutWorkspace.contains("QODER_USER_319") && !withoutWorkspace.contains("PROJECT_ALWAYS_724") && !withoutWorkspace.contains("QODER_PROJECT_418")
            checks["bothCompatibilityRootsAndNativeProjectRulesLoad"] = initial.contains("USER_ALWAYS_923") && initial.contains("PROJECT_ALWAYS_724") && initial.contains("QODER_USER_319") && initial.contains("QODER_PROJECT_418")
            checks["initialContextContainsDecisionDescriptionButNoUnselectedBodies"] = initial.contains("核对公开 README 中的项目元信息") && !initial.contains("LOCAL_MANUAL_625") && !initial.contains("LOCAL_DECISION_BODY_526") && !initial.contains("LOCAL_GLOB_427")
            checks["unaccessedNestedAndOutsideParentRulesDoNotEnterContext"] = !initial.contains("NESTED_NATIVE_617") && !initial.contains("NESTED_QODER_716") && !initial.contains("RULE_PARENT_OUTSIDE_815")
            let tools = AgentTools(store: tasks, taskID: id), otherTools = AgentTools(store: tasks, taskID: other)
            let listed = try await tools.execute(call("list_rules", [:]))
            report["listedRuleReceipt"] = listed.text
            let catalog = try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any], listedRules = catalog?["rules"] as? [[String: Any]] ?? []
            checks["modelCatalogContainsDecisionMetadataOnly"] = listedRules.contains { $0["id"] as? String == decision.id && $0["name"] as? String == decision.invocation } && !listedRules.contains { $0["id"] as? String == manual.id } && !listed.text.contains("LOCAL_DECISION_BODY_526")
            let beforeManual = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            do { _ = try await tools.execute(call("read_rule", ["id": manual.id])); checks["modelCannotSelectUnchosenManualRule"] = false }
            catch { checks["modelCannotSelectUnchosenManualRule"] = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == beforeManual }
            let loaded = try await tools.execute(call("read_rule", ["id": decision.id]))
            checks["readRuleUsesDynamicSystemContextAndSourceHashReceipt"] = try context(id).contains("LOCAL_DECISION_BODY_526") && loaded.text.contains(decision.sha256) && !loaded.text.contains("LOCAL_DECISION_BODY_526") && loaded.sources == [decision.source.absoluteString]
            let failedBefore = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json"))
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/deep/missing.ts"])); checks["failedReadDoesNotActivateRulesOrDiscoverDirectories"] = false }
            catch { checks["failedReadDoesNotActivateRulesOrDiscoverDirectories"] = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json")) == failedBefore }
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/linked.ts"])); checks["symlinkCannotActivateOutsideWorkspaceRules"] = false }
            catch { checks["symlinkCannotActivateOutsideWorkspaceRules"] = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json")) == failedBefore }
            let read = try await tools.execute(call("read_file", ["path": "src/deep/api.ts", "limit": 3]))
            let accessed = try context(id)
            checks["actualReadActivatesProjectAndWorkspaceRelativeUserGlobs"] = !read.failed && accessed.contains("LOCAL_GLOB_427") && accessed.contains("USER_GLOB_328")
            checks["actualReadDiscoversOnlyWorkspaceAncestorRuleDirectories"] = accessed.contains("NESTED_NATIVE_617") && accessed.contains("NESTED_QODER_716") && accessed.contains("NESTED_GLOB_914") && !accessed.contains("RULE_PARENT_OUTSIDE_815") && task(id).ruleDirectories?.map(\.path) == ["src", "src/deep"]
            checks["fileActivationDoesNotCrossTasksOrChangePublicSource"] = try !context(other).contains("LOCAL_GLOB_427") && !context(other).contains("NESTED_NATIVE_617") && Data(contentsOf: sourceURL) == source
            _ = try await otherTools.execute(call("read_file", ["path": "src/vendor/excluded.ts", "limit": 1]))
            checks["excludedActualFileDoesNotActivateProjectGlob"] = try !context(other).contains("LOCAL_GLOB_427")
            let permission = task(id).permission, input = "@rule:" + manual.invocation + " 保留原始要求并核对公开来源"
            checks["explicitChoiceLoadsManualRuleWithoutCopyingItsBodyIntoHistory"] = try runtime.submit(input, taskID: id, startImmediately: false) && context(id).contains("LOCAL_MANUAL_625") && task(id).messages.last?.content == input && task(id).messages.last?.localRuleReferences == [AgentLocalRuleReference(id: manual.id, workspace: project.path)] && task(id).messages.last?.extensionInstructions == nil
            checks["rulesDoNotChangeAskModeOrToolPermissions"] = task(id).mode == .ask && task(id).permission == permission
            let queueID = tasks.create(title: "排队规则选择", workspace: project.path, mode: .ask, workMode: .general), message = try runtime.prepareInput(input, attachmentIDs: [], task: task(queueID))
            tasks.update(queueID) { $0.queuedMessages = [message] }
            let queuedOnly = try !context(queueID).contains("LOCAL_MANUAL_625")
            tasks.update(queueID) { $0.flushQueuedInputs() }
            checks["queuedRuleSelectionActivatesOnlyWhenInputIsFlushed"] = try queuedOnly && context(queueID).contains("LOCAL_MANUAL_625")
            var moved = task(id); moved.workspace = output.appendingPathComponent("other project").path
            let movedContext = try rules.context(moved).text
            checks["oldSelectionsAndDiscoveredDirectoriesDoNotLeakAcrossWorkspaceChange"] = movedContext.contains("USER_ALWAYS_923") && !movedContext.contains("LOCAL_MANUAL_625") && !movedContext.contains("LOCAL_GLOB_427") && !movedContext.contains("NESTED_NATIVE_617")
            var documentation = task(id); documentation.kind = "wiki"
            var hookTask = task(id); hookTask.kind = "hook"
            checks["documentationAndHookJobsExcludeOrdinaryRules"] = try rules.context(documentation).text.isEmpty && rules.context(hookTask).text.isEmpty
            let writeID = tasks.create(title: "实际写入匹配", workspace: project.path, mode: .agent, workMode: .general), editID = tasks.create(title: "实际编辑匹配", workspace: project.path, mode: .agent, workMode: .general)
            tasks.update(writeID) { $0.permission = .automatic }; tasks.update(editID) { $0.permission = .automatic }
            let writer = AgentTools(store: tasks, taskID: writeID), editor = AgentTools(store: tasks, taskID: editID)
            let write = try await writer.execute(call("write_file", ["path": "generated/readme.txt", "content": String(decoding: source, as: UTF8.self)]))
            checks["actualSuccessfulWriteActivatesMatchingRule"] = try !write.failed && context(writeID).contains("ACTUAL_WRITE_GLOB_229") && Data(contentsOf: project.appendingPathComponent("generated/readme.txt")) == source
            let edit = try await editor.execute(call("edit_file", ["path": "edit/review.md", "old_text": "Acceptance before 3827", "new_text": "Acceptance after 3827"]))
            checks["actualSuccessfulEditActivatesMatchingRule"] = try !edit.failed && context(editID).contains("ACTUAL_EDIT_GLOB_130") && String(contentsOf: project.appendingPathComponent("edit/review.md"), encoding: .utf8) == "Acceptance after 3827\n"
            let newText = try AgentRuleDocument.text(name: manual.name, trigger: .manual, description: "", patterns: [], body: "LOCAL_MANUAL_FRESH_813")
            try Data(newText.utf8).write(to: manual.source, options: .atomic)
            checks["externalEditIsReadAtNextTurnWithoutRestart"] = try context(id).contains("LOCAL_MANUAL_FRESH_813") && !context(id).contains("LOCAL_MANUAL_625")
            do { _ = try rules.save(manual, text: manual.text!, task: task(id)); checks["staleEditorCannotOverwriteActualExternalChange"] = false }
            catch { checks["staleEditorCannotOverwriteActualExternalChange"] = try Data(contentsOf: manual.source) == Data(newText.utf8) }
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: manual.source.path)
            let fresh = try rules.current(manual.id, task: task(id)), saved = try rules.save(fresh, text: newText.replacingOccurrences(of: "813", with: "814"), task: task(id))
            checks["explicitFreshSavePreservesPermissionsAndUpdatesContext"] = try context(id).contains("LOCAL_MANUAL_FRESH_814") && (fm.attributesOfItem(atPath: saved.source.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640
            try rules.setEnabled(saved, false, task: task(id)); let disabled = try rules.current(saved.id, task: task(id), enabledOnly: false)
            checks["disabledLocalRuleNoLongerEntersCurrentContext"] = try !context(id).contains("LOCAL_MANUAL_FRESH_814")
            do { _ = try runtime.prepareInput(input, attachmentIDs: [], task: task(id)); checks["disabledRuleCannotBeExplicitlySelected"] = false } catch { checks["disabledRuleCannotBeExplicitlySelected"] = true }
            try rules.setEnabled(disabled, true, task: task(id))
            let damagedURL = store.directory.appendingPathComponent("extensions/rules/damaged.md"); try Data([0xff, 0xfe, 0x80]).write(to: damagedURL)
            let damaged = try rules.catalog(workspace: project.path).first { $0.source == damagedURL }!
            do { _ = try context(id); checks["enabledUnreadableRuleFailsClosedWithSourceDiagnostic"] = false } catch { checks["enabledUnreadableRuleFailsClosedWithSourceDiagnostic"] = error.localizedDescription.contains(damagedURL.path) }
            try rules.setEnabled(damaged, false, task: task(id))
            checks["disabledDamagedRuleDoesNotBlockUnrelatedWork"] = (try? context(id)) != nil
            let repaired = try rules.save(damaged, text: AgentRuleDocument.text(name: "damaged", trigger: .manual, description: "", patterns: [], body: "修复后的公开规则"), task: task(id))
            checks["repairKeepsExplicitDisabledState"] = repaired.definition != nil && !repaired.enabled
            let disposable = try make("native-trash-acceptance", .manual, "NATIVE_RECOVERABLE_TRASH_714")
            let trash = try rules.trash(disposable, task: task(id))
            checks["nativeRemovalUsesRecoverableTrashAndPreservesExactBytes"] = try !fm.fileExists(atPath: disposable.source.path) && trash.map { try Data(contentsOf: $0) == Data(disposable.text!.utf8) } == true
            report["nativeTrashDestination"] = trash?.path
            do { _ = try rules.catalog(workspace: output.appendingPathComponent("linked project").path); checks["symlinkedRuleRootCannotPromoteOutsideFolderIntoTrust"] = false } catch { checks["symlinkedRuleRootCannotPromoteOutsideFolderIntoTrust"] = true }
            do { _ = try make("../outside", .always, "不应写入"); checks["invalidNewNameCannotEscapeRuleRoot"] = false } catch { checks["invalidNewNameCannotEscapeRuleRoot"] = !fm.fileExists(atPath: project.appendingPathComponent(".bluefatfish/outside.md").path) }
            let roundTrip = try AgentRuleDocument.text(name: "quoted-rule", trigger: .decision, description: "核对 \"项目\" 与 C:\\reference", patterns: [], body: "保留原文")
            checks["structuredSavePreservesQuotedDescriptionAndBackslashes"] = try AgentRuleDocument.parse(roundTrip, path: "quoted-rule.md", fallback: "quoted-rule").description == "核对 \"项目\" 与 C:\\reference"
            let capProfile = output.appendingPathComponent("cap-profile"); try fm.createDirectory(at: capProfile, withIntermediateDirectories: true)
            let capStore = AgentStore(directory: capProfile, legacy: [], extensionHome: nil), capPlugin = try capStore.extensions.plugins.install(await capStore.extensions.plugins.inspect(output.appendingPathComponent("limit-rules.zip")))
            try capStore.extensions.plugins.setEnabled(capPlugin, true)
            _ = try capStore.rules.create(name: "limit", text: String(repeating: "B", count: 60_000), project: false, task: capStore.selected!)
            let capped = try capStore.rules.context(capStore.selected!).text
            checks["pluginAndLocalRulesShareOne100000CharacterBodyLimit"] = capped.filter { $0 == "A" }.count == 60_000 && capped.filter { $0 == "B" }.count == 40_000 && capped.contains("已截断")
            let slow = tasks.create(title: "规则变化实际取消", workspace: project.path, mode: .agent, workMode: .general)
            guard runtime.submit(input, taskID: slow, startImmediately: false) else { throw PetError(runtime.submissionError ?? "未保存规则选择") }
            let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let command = "'" + node.replacingOccurrences(of: "'", with: "'\\''") + "' slow.cjs", pending = try call("run_command", ["command": command, "timeout_seconds": 40, "network": false])
            tasks.update(slow) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(slow)
            let pidFile = project.appendingPathComponent("slow-pids.json")
            guard await waitUntil({ fm.fileExists(atPath: pidFile.path) && runtime.isRunning(slow) }), let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as? [String: Int], let parent = pids["pid"], let child = pids["child"] else { throw PetError("实际核对进程尚未启动") }
            checks["actualSelectedRuleTaskOwnsLiveParentAndChildProcesses"] = kill(pid_t(parent), 0) == 0 && kill(pid_t(child), 0) == 0
            try rules.setEnabled(rules.current(manual.id, task: task(slow)), false, task: task(slow))
            checks["ruleDisableCancelsActualTaskAndItsChildProcess"] = await waitUntil { !runtime.isRunning(slow) && kill(pid_t(parent), 0) != 0 && kill(pid_t(child), 0) != 0 }
            try rules.setEnabled(rules.current(manual.id, task: task(id), enabledOnly: false), true, task: task(id))
            let raw = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")), decoded = try JSONDecoder().decode(AgentTaskRecord.self, from: raw)
            checks["serializedSelectionsAndNestedDiscoveryReloadIntoFreshService"] = try AgentRules(profile: store.directory, sharedHome: output.appendingPathComponent("shared-home"), plugins: AgentPlugins(profile: store.directory)).context(decoded).text.contains("LOCAL_MANUAL_FRESH_814") && decoded.ruleDirectories == task(id).ruleDirectories
            let ui = tasks.create(title: "用户和项目规则窗口验收", workspace: project.path, mode: .ask, workMode: .general); tasks.update(ui) { $0.draft = "保留用户规则原草稿" }; tasks.selectedID = ui
            checks["noModelReceiptOrAssistantResponseWasCreated"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains(where: { $0.role == "assistant" }) != true }
            report["actualCancelledPIDs"] = [parent, child]; report["sourceHash"] = AgentFiles.hash(source); report["uiTaskID"] = ui; report["checkedTaskID"] = id
            report["runtimeContext"] = try context(id); report["globalContext"] = try context(global)
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentRuntime?.isWorking != true
        report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["scope"] = "Actual user/project/Qoder rule files, native tool reads and writes, nested discovery, file-version conflicts, recoverable native trash and actual process cancellation. External model transmission blocked; rule-following quality and GUI deletion are not claimed."
        if let executable = Bundle.main.executableURL, let data = try? Data(contentsOf: executable) { report["binaryHash"] = AgentFiles.hash(data) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("local-rule-result.json"))
    }
}
