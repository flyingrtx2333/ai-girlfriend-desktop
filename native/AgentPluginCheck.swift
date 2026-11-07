import AppKit

@MainActor extension AppDelegate {
    func runAgentPluginCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func waitFor(_ name: String) async throws {
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent(name).path) { await wait(0.1) }
            guard fm.fileExists(atPath: output.appendingPathComponent(name).path) else { throw PetError("等待实际界面操作超时：" + name) }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "plugin-process.json")
            let library = tasks.extensions, plugins = library.plugins, workspace = output.appendingPathComponent("repo"), nativeZip = output.appendingPathComponent("native-plugin.zip")
            let nativeHash = AgentFiles.hash(try Data(contentsOf: nativeZip)), nativeReport = output.appendingPathComponent("plugin-native-report.json")
            if fm.fileExists(atPath: nativeReport.path) {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeReport)) as! [String: Any]
                guard previous["success"] as? Bool == true, previous["sourceHash"] as? String == nativeHash, let values = previous["checks"] as? [String: Bool] else { throw PetError("原生插件检查未通过，不能跳过") }; checks = values
            } else {
                let package = try await plugins.inspect(nativeZip), installed = try plugins.install(package)
                checks["archiveInstallsManifestSkillCommandAndReferences"] = installed.receipt.components.count == 2 && installed.receipt.hashes.count == package.files.count && installed.metadata.name == "native-plugin"
                checks["installationStartsDisabled"] = try !installed.receipt.enabled && library.catalog(workspace: workspace.path, includeDisabled: false).allSatisfy { $0.pluginName != installed.id }
                do { _ = try plugins.install(package); checks["existingPluginIsNotOverwritten"] = false } catch { checks["existingPluginIsNotOverwritten"] = try plugins.installation(installed.id).receiptHash == installed.receiptHash }
                try plugins.setEnabled(installed, true)
                let entries = try library.catalog(workspace: workspace.path).filter { $0.pluginName == installed.id }, skill = entries.first { $0.kind == .skill }!, command = entries.first { $0.kind == .command }!
                checks["allComponentNamesAreScopedToParent"] = Set(entries.map(\.name)) == Set(["native-plugin:check", "native-plugin:count"]) && entries.allSatisfy { $0.enabled && !$0.managed }
                do { try library.setEnabled(skill, enabled: false, workspace: workspace.path); checks["componentsCannotBypassParentLifecycle"] = false } catch { checks["componentsCannotBypassParentLifecycle"] = true }
                let id = tasks.create(title: "插件原生边界", workspace: workspace.path, mode: .ask), message = AgentMessage(role: "user", content: "/" + command.invocation + " 实际参数")
                let expanded = try library.expand(message, store: tasks, taskID: id)
                checks["packagedCommandRoutesAndExpandsActualArguments"] = expanded.content == message.content && expanded.extensionInstructions?.contains("实际参数") == true && expanded.extensionInstructions?.contains("$ARGUMENTS") == false
                let (reference, _) = try library.activate(skill.id, store: tasks, taskID: id, explicit: true); tasks.update(id) { $0.activeSkills = [reference] }
                let before = try library.readResource(skill.id, path: "references/check.txt", offset: 1, store: tasks, taskID: id)
                let resource = skill.root.appendingPathComponent("references/check.txt"), bytes = try Data(contentsOf: resource)
                try Data("changed content".utf8).write(to: resource, options: .atomic)
                do { _ = try library.activate(skill.id, store: tasks, taskID: id, explicit: true); checks["changedPackageResourcesCannotBeLoaded"] = false } catch { checks["changedPackageResourcesCannotBeLoaded"] = true }
                try bytes.write(to: resource, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: resource.path)
                try plugins.setEnabled(plugins.installation(installed.id), false)
                do { _ = try library.readResource(skill.id, path: "references/check.txt", offset: 1, store: tasks, taskID: id); checks["parentDisableBlocksPinnedResourceReads"] = false } catch { checks["parentDisableBlocksPinnedResourceReads"] = before.contains("native-reference") }
                checks["parentDisableSurvivesServiceReload"] = try AgentExtensions(profile: library.profile, sharedHome: library.sharedHome).plugins.installation(installed.id).receipt.enabled == false
                checks["installedPayloadRemainsPrivateAndReadOnly"] = (try fm.attributesOfItem(atPath: skill.file.path)[.posixPermissions] as? Int) == 0o400
                for (file, key) in [("traversal.zip", "archiveTraversalRejected"), ("duplicate.zip", "archivePathAliasesRejected"), ("unsupported.zip", "unsupportedComponentsAreRejectedBeforeInstall"), ("missing.zip", "missingDeclaredComponentsAreRejected")] {
                    do { _ = try await plugins.inspect(output.appendingPathComponent(file)); checks[key] = false } catch { checks[key] = true }
                }
                let oldSkill = try await library.importItem(output.appendingPathComponent("ordinary.skill"), kind: .skill, project: false, workspace: workspace.path)
                checks["ordinarySkillZipStillUsesSharedSafeReader"] = oldSkill.name == "ordinary-check" && oldSkill.pluginName == nil
                guard checks.values.allSatisfy({ $0 }) else { throw PetError("插件原生检查未通过") }
                try write(["success": true, "checks": checks, "sourceHash": nativeHash], nativeReport.lastPathComponent)
            }
            if CommandLine.arguments.contains("--live-agent") {
                let owner = output.appendingPathComponent("plugin-live-task.json"), uiReport = output.appendingPathComponent("plugin-live-ui-report.json"), id: String, skillID: String
                let intent = "/skill:sales-workbench:review-sales 读取当前项目 sales.csv，按插件资源约定生成 summary.json，再回读核对。保留输入文件。"
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                report["preferences"] = ["context": preferences.contextLimit, "output": preferences.outputLimit, "productionSettingsWritten": false]
                if fm.fileExists(atPath: owner.path) {
                    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let previousID = previous["taskID"], let previousSkill = previous["skillID"], let task = tasks.task(previousID), task.messages.first(where: \.isHumanInput)?.content == intent || task.messages.isEmpty else { throw PetError("原真实插件任务不存在，不能替换") }
                    id = previousID; skillID = previousSkill
                    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: uiReport)) as! [String: Bool]; checks.merge(saved) { _, latest in latest }
                } else {
                    let installTask = tasks.create(title: "插件安装验收", workspace: workspace.path, mode: .ask)
                    control.prepareExtensionCheckWindow(taskID: installTask, manager: true)
                    try write(["phase": "install-and-command", "taskID": installTask, "appPID": getpid(), "archive": output.appendingPathComponent("sales-workbench.zip").path], "plugin-ui-ready.json")
                    try await waitFor("start-plugin-workflow")
                    let installed = try plugins.installation("sales-workbench"), prepared = try await plugins.inspect(output.appendingPathComponent("sales-workbench.zip"))
                    checks["actualUIImportsReviewedPackageAndEnablesParent"] = installed.receipt.enabled && installed.receipt.hashes == prepared.receipt.hashes && installed.receipt.sourceHash == prepared.receipt.sourceHash
                    let draft = tasks.task(installTask)?.draft ?? ""
                    checks["actualUIInsertsPackagedCommandWithoutSending"] = draft.hasPrefix("/command:sales-workbench:handoff ") && tasks.task(installTask)?.messages.isEmpty == true
                    guard checks["actualUIImportsReviewedPackageAndEnablesParent"] == true, checks["actualUIInsertsPackagedCommandWithoutSending"] == true, let skill = try library.catalog(workspace: workspace.path, includeDisabled: false).first(where: { $0.name == "sales-workbench:review-sales" && $0.kind == .skill }) else { throw PetError("实际插件安装、启用或命令插入尚未完成") }
                    skillID = skill.id
                    let profile = AgentProfile(name: "实际插件工作流", description: "读取插件与当前数据，生成并回读实际文件", instructions: "按选定 Skill 和当前实际输入完成任务。", tools: ["read_file", "write_file"], readOnly: false, network: false, enabled: true, skills: [skill.id])
                    let (_, version) = try tasks.agents.document(); try tasks.agents.save(tasks.agents.encode(tasks.agents.list() + [profile]), expectedHash: version)
                    id = try tasks.agents.createTask(profile.id, store: tasks, workspace: workspace.path); tasks.update(id) { $0.title = "插件实际销售核对" }
                    try write(["taskID": id, "skillID": skillID], owner.lastPathComponent)
                    try write(checks.filter { $0.key.hasPrefix("actualUI") }, uiReport.lastPathComponent)
                }
                if tasks.task(id)?.messages.isEmpty == true {
                    control.prepareExtensionCheckWindow(taskID: id, manager: true)
                    try write(["phase": "use-skill", "taskID": id, "appPID": getpid(), "intent": intent], "plugin-ui-ready.json")
                    try await waitFor("verify-plugin-skill-draft")
                    checks["actualUISkillInsertionDoesNotSendModelRequest"] = tasks.task(id)?.draft?.hasPrefix("/skill:sales-workbench:review-sales ") == true && tasks.task(id)?.messages.isEmpty == true && (tasks.task(id)?.modelReceipts ?? []).isEmpty
                    guard checks["actualUISkillInsertionDoesNotSendModelRequest"] == true else { throw PetError("真实 Skill 草稿未核对") }
                    try write(checks.filter { $0.key.hasPrefix("actualUI") }, uiReport.lastPathComponent)
                    try write(["phase": "ready-to-send", "taskID": id, "appPID": getpid()], "plugin-ui-ready.json")
                } else if tasks.task(id)?.status != .completed { runtime.start(id) }
                var approvals = 0; let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline {
                    guard let task = tasks.task(id) else { throw PetError("真实插件任务丢失") }
                    if (task.modelReceipts ?? []).count > 8 { runtime.cancel(id); throw PetError("真实插件任务超过本轮8次请求上限，保留原任务") }
                    if task.status == .waiting, let pending = task.pendingCalls.first {
                        guard pending.name == "write_file", let path = pending.object["path"] as? String, try AgentFiles(workspace: workspace.path).resolve(path) == workspace.appendingPathComponent("summary.json"), approvals < 2 else { throw PetError("真实插件任务提出预期外审批") }
                        runtime.decide(taskID: id, callID: pending.id, decision: "allow"); approvals += 1
                    }
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实插件任务失败：" + (task.events.last?.detail ?? "")) }; await wait(0.1)
                }
                guard let task = tasks.task(id), task.status == .completed, task.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("真实插件任务未完成或原始输入变化") }
                let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("summary.json"))) as? [String: Any]
                checks["realPluginSkillReadsActualReferenceAndCreatesCorrectFile"] = task.activeSkills?.contains(where: { $0.id == skillID }) == true && task.events.contains(where: { $0.title == "read_skill_resource" && $0.status == "completed" }) && actual?["total"] as? String == "43.65" && actual?["currency"] as? String == "CNY" && actual?["rows"] as? Int == 3 && actual?["review"] as? [String] == ["C"]
                let calls = task.messages.flatMap { $0.toolCalls ?? [] }, writeIndex = calls.firstIndex { $0.name == "write_file" }
                checks["realModelReadsBackSavedOutput"] = writeIndex.map { calls.dropFirst($0 + 1).contains { $0.name == "read_file" && ($0.object["path"] as? String).map { $0 == "summary.json" || $0 == workspace.appendingPathComponent("summary.json").path } == true } } == true
                guard checks["realPluginSkillReadsActualReferenceAndCreatesCorrectFile"] == true, checks["realModelReadsBackSavedOutput"] == true else { throw PetError("真实插件结果或回读未通过") }
                control.showAgentTask(id); control.show(tab: "chat")
                try write(["phase": "completed", "taskID": id, "appPID": getpid(), "requests": task.modelReceipts?.count ?? 0], "plugin-ui-ready.json")
                if CommandLine.arguments.contains("--hold-ui") {
                    try await waitFor("verify-plugin-disabled")
                    checks["actualUIDisablePersistsAndBlocksLoadedSkill"] = try !plugins.installation("sales-workbench").receipt.enabled
                    do { _ = try library.readResource(skillID, path: "references/report.json", offset: 1, store: tasks, taskID: id); checks["actualUIDisableBlocksResourceRead"] = false } catch { checks["actualUIDisableBlocksResourceRead"] = true }
                    try write(["checks": checks.filter { $0.key.hasPrefix("actualUIDisable") }], "plugin-disabled-verified.json")
                    try await waitFor("finish-plugin-ui")
                    checks["actualUIReenableRestoresScopedComponents"] = try plugins.installation("sales-workbench").receipt.enabled && library.item(skillID, workspace: workspace.path).enabled
                }
                let final = tasks.task(id)!
                checks["uiLifecycleAddsNoModelRequestsOrHistory"] = final.messages.map(\.id) == task.messages.map(\.id) && final.modelReceipts?.count == task.modelReceipts?.count
                report["live"] = ["taskID": id, "skillID": skillID, "model": preferences.model, "requests": final.modelReceipts?.count ?? 0, "inputTokens": final.inputTokens, "outputTokens": final.outputTokens, "approvals": final.approvals.filter { $0.decision == "allow" }.count]
            }
            report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }; try write(report, "plugin-report.json"); runtime.stopAll()
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "plugin-report.json"); agentRuntime?.stopAll() }
    }
}
