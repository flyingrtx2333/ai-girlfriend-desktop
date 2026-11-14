import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentPluginRuleCheck(_ output: URL) async {
        let fm = FileManager.default; var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        func waitUntil(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while !test() && Date() < end { await wait(0.03) }; return test() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("插件规则原生检查禁止模型请求") }
            let plugins = tasks.extensions.plugins, project = output.appendingPathComponent("real project")
            let source = try Data(contentsOf: project.appendingPathComponent("src/api.ts")), sourceHash = AgentFiles.hash(source)
            let inspected = try await plugins.inspect(output.appendingPathComponent("native-rules.zip")), installed = try plugins.install(inspected)
            func rule(_ key: String) throws -> AgentPluginRuleItem { guard let value = try plugins.ruleItems().first(where: { $0.name == installed.id + ":" + key }) else { throw PetError("未找到规则：" + key) }; return value }
            let id = tasks.create(title: "插件规则实际读取", workspace: project.path, mode: .ask, workMode: .general)
            let other = tasks.create(title: "规则未匹配的独立任务", workspace: project.path, mode: .ask, workMode: .general)
            func context(_ taskID: String) throws -> String { try runtime.systemContext(tasks.task(taskID)!) }
            func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)) }
            checks["rulesOnlyPackageLoadsAllFourTriggers"] = installed.rules.count == 4 && Set(installed.rules.map { $0.trigger.rawValue }) == ["always_on", "manual", "model_decision", "glob"] && installed.receipt.components.isEmpty && installed.hooks.isEmpty && installed.agents.isEmpty && installed.mcpServers.isEmpty
            checks["installationDoesNotInjectDisabledRules"] = try !context(id).contains("RULE_ALWAYS_381") && plugins.ruleItems().allSatisfy { !$0.enabled }
            let originalPermission = tasks.task(id)!.permission
            let before = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            do { _ = try runtime.prepareInput("@rule:native-rules:manual 核对来源", attachmentIDs: [], task: tasks.task(id)!); checks["disabledManualChoiceCannotLeaveHalfTask"] = false } catch { checks["disabledManualChoiceCannotLeaveHalfTask"] = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == before }
            try plugins.setEnabled(installed, true)
            let initial = try context(id)
            checks["onlyAlwaysBodyAndDecisionDescriptionEnterInitialContext"] = initial.contains("RULE_ALWAYS_381") && initial.contains("核对项目元信息时选择") && !initial.contains("RULE_DECISION_BODY_482") && !initial.contains("RULE_MANUAL_583") && !initial.contains("RULE_GLOB_684")
            let tools = AgentTools(store: tasks, taskID: id), otherTools = AgentTools(store: tasks, taskID: other)
            let listed = try await tools.execute(call("list_rules", [:]))
            checks["actualCatalogExposesDecisionMetadataWithoutBodiesOrManualRules"] = listed.text.contains("native-rules:decision") && !listed.text.contains("RULE_DECISION_BODY_482") && !listed.text.contains("native-rules:manual")
            do { _ = try await tools.execute(call("read_rule", ["id": rule("manual").id])); checks["modelCannotAutomaticallyLoadManualRule"] = false } catch { checks["modelCannotAutomaticallyLoadManualRule"] = tasks.task(id)?.activeRules?.isEmpty != false }
            let decision = try await tools.execute(call("read_rule", ["id": rule("decision").id]))
            checks["actualReadRuleLoadsCurrentBodyOnlyIntoDynamicContext"] = try context(id).contains("RULE_DECISION_BODY_482") && !decision.text.contains("RULE_DECISION_BODY_482") && decision.text.contains(rule("decision").reference.sha256)
            checks["ruleLoadingDoesNotChangeTaskPermissions"] = tasks.task(id)?.mode == .ask && tasks.task(id)?.permission == originalPermission
            _ = try await otherTools.execute(call("read_file", ["path": "src/vendor/excluded.ts", "limit": 2]))
            checks["excludedActualFileDoesNotActivateGlob"] = try !context(other).contains("RULE_GLOB_684") && tasks.task(other)?.activeRules?.isEmpty != false
            // Successful reads now remember local-rule directories in their own
            // task. Compare isolation after that intentional local mutation.
            let otherBefore = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json"))
            let read = try await tools.execute(call("read_file", ["path": "src/api.ts", "limit": 2]))
            checks["actualPublicFileReadActivatesMatchingRule"] = try !read.failed && !read.text.isEmpty && context(id).contains("RULE_GLOB_684") && Data(contentsOf: project.appendingPathComponent("src/api.ts")) == source
            checks["matchingRuleDoesNotCrossTasks"] = try !context(other).contains("RULE_GLOB_684") && Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json")) == otherBefore
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/missing.ts"])); checks["failedFileAccessDoesNotActivateRule"] = false } catch { checks["failedFileAccessDoesNotActivateRule"] = tasks.task(other)?.activeRules?.isEmpty != false }
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/linked.ts"])); checks["actualSymlinkCannotLoadOutsideWorkspace"] = false } catch { checks["actualSymlinkCannotLoadOutsideWorkspace"] = tasks.task(other)?.activeRules?.isEmpty != false }
            let manualText = "@rule:native-rules:manual 保留原始要求并核对公开文件"
            checks["explicitManualInputLoadsRuleWithoutCopyingBodyIntoHistory"] = try runtime.submit(manualText, taskID: id, startImmediately: false) && context(id).contains("RULE_MANUAL_583") && tasks.task(id)?.messages.last?.content == manualText && tasks.task(id)?.messages.last?.extensionInstructions == nil
            let saved = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")), decoded = try JSONDecoder().decode(AgentTaskRecord.self, from: saved)
            checks["ruleReferencesReloadWithoutMutatingImmutablePackage"] = try AgentPlugins(profile: store.directory,sharedHome:plugins.sharedHome).ruleContext(decoded).text.contains("RULE_MANUAL_583") && installed.receipt.hashes.allSatisfy { path, hash in (try? plugins.content(path, installation: plugins.installation(installed.id))).map(AgentFiles.hash) == hash }
            var moved = decoded; moved.workspace = output.appendingPathComponent("other project").path
            checks["previousWorkspaceSelectionsDoNotLeakToAnotherWorkspace"] = try !plugins.ruleContext(moved).text.contains("RULE_MANUAL_583") && !plugins.ruleContext(moved).text.contains("RULE_GLOB_684")
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("glob-oracle.json"))) as! [[String: Any]]
            checks["globResultsMatchIndependentActualGitIgnoreOracle"] = try fixture.allSatisfy { row in try AgentPlugins.ruleMatches(row["patterns"] as! [String], path: row["path"] as! String) == row["matched"] as! Bool }
            let slow = tasks.create(title: "规则父插件实际取消", workspace: project.path, mode: .agent, workMode: .general)
            guard runtime.submit("@rule:native-rules:manual 运行本目录的公开核对脚本", taskID: slow, startImmediately: false) else { throw PetError(runtime.submissionError ?? "未保存核对要求") }
            let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let command = "'" + node.replacingOccurrences(of: "'", with: "'\\''") + "' slow.cjs", pending = try call("run_command", ["command": command, "timeout_seconds": 40, "network": false])
            tasks.update(slow) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(slow)
            let pidFile = project.appendingPathComponent("slow-pids.json")
            guard await waitUntil({ fm.fileExists(atPath: pidFile.path) && runtime.isRunning(slow) }), let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as? [String: Int], let parent = pids["pid"], let child = pids["child"] else { throw PetError("实际核对进程尚未启动") }
            checks["actualRuntimeOwnsLiveParentAndChild"] = kill(pid_t(parent), 0) == 0 && kill(pid_t(child), 0) == 0 && runtime.isRunning(slow)
            let old = try rule("manual").reference
            try plugins.setEnabled(plugins.installation(installed.id), false)
            checks["parentDisableCancelsActualSelectedRuleTaskAndChild"] = await waitUntil { !runtime.isRunning(slow) && kill(pid_t(parent), 0) != 0 && kill(pid_t(child), 0) != 0 }
            checks["disabledRulesAreRemovedFromCurrentContext"] = try !context(id).contains("RULE_ALWAYS_381") && !context(id).contains("RULE_MANUAL_583") && !context(id).contains("RULE_DECISION_BODY_482") && !context(id).contains("RULE_GLOB_684")
            let resource = installed.root.appendingPathComponent("payload/resources/reference.txt"), original = try Data(contentsOf: resource)
            try Data("changed public reference".utf8).write(to: resource, options: .atomic)
            checks["disabledDamagedPackageDoesNotBlockUnrelatedContext"] = (try? context(other)) != nil
            try original.write(to: resource, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: resource.path)
            try plugins.setEnabled(plugins.installation(installed.id), true)
            checks["reenableRestoresAutomaticRuleButNotOldManualDecisionOrGlobBindings"] = try context(id).contains("RULE_ALWAYS_381") && !context(id).contains("RULE_MANUAL_583") && !context(id).contains("RULE_DECISION_BODY_482") && !context(id).contains("RULE_GLOB_684")
            var stale = old; stale.workspace = project.path
            do { try plugins.activateRule(stale, store: tasks, taskID: id); checks["staleSelectionCannotAuthorizeNewActivation"] = false } catch { checks["staleSelectionCannotAuthorizeNewActivation"] = true }
            checks["explicitFreshSelectionRestoresManualRule"] = try runtime.submit("@rule native-rules:manual 再次选择当前规则", taskID: id, startImmediately: false) && context(id).contains("RULE_MANUAL_583")
            try Data("changed public reference".utf8).write(to: resource, options: .atomic)
            do { _ = try context(id); checks["changedActualPackageResourceCannotEnterContext"] = false } catch { checks["changedActualPackageResourceCannotEnterContext"] = true; report["resourceFailure"] = error.localizedDescription }
            try original.write(to: resource, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: resource.path)
            for (name, key) in [("declared-rules.zip", "declaredPathsAndCompatibilityMetadataParse"), ("precedence-rules.zip", "explicitTriggerPrecedesCompatibilityFlag"), ("bom-rules.zip", "BOMAndCarriageReturnsDoNotTurnManualIntoAutomaticRule")] {
                let value = try await plugins.inspect(output.appendingPathComponent(name))
                checks[key] = name == "declared-rules.zip" ? value.rules.count == 1 && value.rules[0].trigger == .glob && value.rules[0].patterns.count == 2 : value.rules.count == 1 && value.rules[0].trigger == .manual
            }
            for (name, key) in [("bad-trigger.zip", "unknownTriggerRejected"), ("bad-decision.zip", "decisionWithoutDescriptionRejected"), ("bad-boolean.zip", "malformedCompatibilityFlagRejected"), ("bad-glob.zip", "invalidGlobRejected"), ("bad-pattern-type.zip", "booleanPatternCannotSilentlyBecomeFilename"), ("orphan-rules.zip", "orphanRuleDirectoryRejected"), ("bad-field.zip", "unknownRuleFieldRejected"), ("duplicate-rules.zip", "duplicateDeclaredPathsRejected")] { do { _ = try await plugins.inspect(output.appendingPathComponent(name)); checks[key] = false } catch { checks[key] = true } }
            try plugins.setEnabled(plugins.installation(installed.id), false)
            let ui = tasks.create(title: "插件规则窗口验收", workspace: project.path, mode: .ask, workMode: .general); tasks.update(ui) { $0.draft = "保留插件规则原草稿" }; tasks.selectedID = ui
            checks["actualPublicSourceRemainsOriginal"] = try Data(contentsOf: project.appendingPathComponent("src/api.ts")) == source
            checks["noModelAttemptReceiptOrAssistantResponseWasCreated"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains(where: { $0.role == "assistant" }) != true }
            report["sourceHash"] = sourceHash; report["actualCancelledPIDs"] = [parent, child]; report["checkedTaskID"] = id; report["uiTaskID"] = ui; report["globOracleCases"] = fixture.count
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentRuntime?.isWorking != true
        report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["scope"] = "Actual plugin ZIPs, four rule triggers, native tool dispatch and actual project reads, Git ignore oracle, persistent task bindings and cancellation of actual parent/child processes. No model outputs are substituted; real rule-following quality is not validated."
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-rule-result.json"), options: .atomic)
    }
}
