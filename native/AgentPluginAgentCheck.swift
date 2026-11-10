import AppKit

@MainActor extension AppDelegate {
    func runAgentPluginAgentCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let fm = FileManager.default
        func call(_ name: String, _ arguments: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("插件 Agent 原生检查禁止模型请求") }
            let plugins = tasks.extensions.plugins, service = tasks.agents, workspace = output.appendingPathComponent("repo")
            let ordinary = AgentProfile(name: "保留的本机角色", description: "已有本机配置", instructions: "保留原始本机配置。", enabled: true)
            try service.save(service.encode([ordinary]), expectedHash: nil)
            let config = store.directory.appendingPathComponent("extensions/agents.json"), originalConfig = try Data(contentsOf: config)
            let package = try await plugins.inspect(output.appendingPathComponent("native-roles.zip")), installed = try plugins.install(package)
            checks["archiveDiscoversDeclaredAgentArrayAndBundledReferences"] = package.agents.count == 2 && installed.agents.count == 2 && installed.mcpServers.count == 1 && installed.receipt.components.count == 1
            let disabled = try service.list().filter { $0.pluginSource?.name == installed.id }
            checks["installationStartsDisabledAndDoesNotAlterLocalAgents"] = try disabled.count == 2 && disabled.allSatisfy { !$0.enabled } && Data(contentsOf: config) == originalConfig
            let readerID = disabled.first { $0.name.hasSuffix(":reviewer") }!.id
            do { _ = try service.createTask(readerID, store: tasks, workspace: workspace.path); checks["disabledPluginCannotStartAgentTask"] = false } catch { checks["disabledPluginCannotStartAgentTask"] = true }
            try plugins.setEnabled(installed, true)
            let reader = try service.profile(readerID), writer = try service.list().first { $0.name == installed.id + ":integrator" }!
            checks["yamlBlockAndInlineToolsUseActualNativeToolNames"] = Set(reader.tools) == ["read_file", "search_files", "list_directory"] && reader.readOnly && !reader.network && reader.permission == .review
            checks["allRoleNamesAndIDsAreScopedToInstallation"] = reader.name == "native-roles:reviewer" && reader.pluginSource?.installationID == installed.instanceID && writer.id != reader.id && UUID(uuidString: reader.id) != nil
            let skill = try tasks.extensions.catalog(workspace: workspace.path).first { $0.name == "native-roles:source" }!, mcp = tasks.mcp.servers.first { $0.plugin?.name == installed.id }!
            checks["packagedSkillAndMCPBindToActualInstalledIDs"] = writer.skills == [skill.id] && writer.mcpServers == [mcp.id] && writer.toolPermissions?["write_file"] == .deny
            let count = tasks.tasks.count
            do { _ = try service.createTask(writer.id, store: tasks, workspace: workspace.path); checks["unconfiguredConnectorCannotCreatePartialAgentTask"] = false } catch { checks["unconfiguredConnectorCannotCreatePartialAgentTask"] = tasks.tasks.count == count }
            let id = try service.createTask(reader.id, store: tasks, workspace: workspace.path, workMode: .general)
            tasks.update(id) { $0.title = "插件角色读取检查"; $0.draft = "保留角色任务草稿" }
            let read = try call("read_file", ["path": "source.txt"]), result = try await AgentTools(store: tasks, taskID: id).execute(read), actualSource = try String(contentsOf: workspace.appendingPathComponent("source.txt"), encoding: .utf8)
            let firstSourceLine = String(actualSource.split(separator: "\n").first ?? "")
            checks["actualRoleTaskReadsRealProjectFile"] = !result.failed && !firstSourceLine.isEmpty && result.text.contains(firstSourceLine) && tasks.task(id)?.agent?.profile.instructions == package.agents.first { $0.key == "reviewer" }?.profile.instructions
            do { _ = try AgentTools(store: tasks, taskID: id).approvalReason(for: call("write_file", ["path": "forbidden.txt", "content": "no"])); checks["readonlyRoleCannotWriteOrRequestBroaderTool"] = false } catch { checks["readonlyRoleCannotWriteOrRequestBroaderTool"] = !fm.fileExists(atPath: workspace.appendingPathComponent("forbidden.txt").path) }
            let beforeTask = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")), beforeModel = tasks.task(id)?.model
            let modelVersion = try service.pluginModelVersion()
            try service.savePluginModel(reader, model: "native-check-model", expectedHash: modelVersion)
            checks["modelOverrideDoesNotModifyPackageLocalAgentsOrExistingTask"] = try service.profile(reader.id).model == "native-check-model" && Data(contentsOf: config) == originalConfig && Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == beforeTask && tasks.task(id)?.model == beforeModel && plugins.content(package.agents.first { $0.key == "reviewer" }!.path, installation: plugins.installation(installed.id)) == package.files[package.agents.first { $0.key == "reviewer" }!.path]
            do { try service.savePluginModel(reader, model: "stale-model", expectedHash: modelVersion); checks["staleModelEditorCannotOverwriteNewerSetting"] = false } catch { checks["staleModelEditorCannotOverwriteNewerSetting"] = try service.profile(reader.id).model == "native-check-model" }
            let refreshed = AgentProfiles(profile: store.directory, plugins: plugins)
            checks["roleIDAndModelOverrideSurviveServiceReload"] = try refreshed.profile(reader.id).model == "native-check-model"
            let taskWithNewModel = try service.createTask(reader.id, store: tasks, workspace: workspace.path)
            checks["newTasksUseLocalModelOverride"] = tasks.task(taskWithNewModel)?.model == "native-check-model"
            let taskBytes = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            try plugins.setEnabled(plugins.installation(installed.id), false)
            do { _ = try await AgentTools(store: tasks, taskID: id).execute(read); checks["parentDisableBlocksExistingTaskTools"] = false } catch { checks["parentDisableBlocksExistingTaskTools"] = true }
            checks["parentDisableRetainsHistoryDraftAndExactTaskRecord"] = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == taskBytes
            try plugins.setEnabled(plugins.installation(installed.id), true)
            do { try service.check(read, task: tasks.task(id)!, store: tasks); checks["reenableCannotReviveOldActivationBinding"] = false } catch { checks["reenableCannotReviveOldActivationBinding"] = true }
            try service.configureDraft(reader.id, taskID: id, store: tasks)
            let reselected = try await AgentTools(store: tasks, taskID: id).execute(read)
            checks["explicitReselectionRestoresRoleAndPreservesDraft"] = !reselected.failed && tasks.task(id)?.draft == "保留角色任务草稿"
            let definition = package.agents.first { $0.key == "reviewer" }!, changed = installed.root.appendingPathComponent("payload/" + definition.path), original = try Data(contentsOf: changed)
            try Data("changed definition\n".utf8).write(to: changed, options: .atomic)
            do { _ = try service.currentProfile(tasks.task(id)!.agent!.profile); checks["changedDefinitionIsRejectedBeforeExecution"] = false } catch { checks["changedDefinitionIsRejectedBeforeExecution"] = true; report["changedDefinitionError"] = error.localizedDescription }
            try original.write(to: changed, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: changed.path)
            checks["payloadRestoredExactlyAndRemainsReadonly"] = try plugins.content(definition.path, installation: plugins.installation(installed.id)) == original && (fm.attributesOfItem(atPath: changed.path)[.posixPermissions] as? Int) == 0o400
            let onlyPackage = try await plugins.inspect(output.appendingPathComponent("agent-only.zip")), only = try plugins.install(onlyPackage)
            checks["agentOnlyConventionalPackageInstallsWithoutSkillOrMCP"] = only.agents.count == 1 && only.mcpServers.isEmpty && only.receipt.components.isEmpty
            for (name, key) in [("missing-agent.zip", "missingDeclaredAgentRejected"), ("duplicate-agent.zip", "duplicateRoleNamesRejected"), ("unknown-tool.zip", "unknownToolCannotSilentlyExpandPermissions"), ("unknown-field.zip", "unsupportedRoleFieldRejectedBeforeInstallation"), ("missing-skill.zip", "missingBundledSkillRejectedBeforeInstallation"), ("duplicate-field.zip", "duplicateRoleFieldRejectedBeforeInstallation")] {
                do { _ = try await plugins.inspect(output.appendingPathComponent(name)); checks[key] = false } catch { checks[key] = true }
            }
            let ordinaryTask = try service.createTask(ordinary.id, store: tasks, workspace: workspace.path), ordinaryRead = try await AgentTools(store: tasks, taskID: ordinaryTask).execute(read)
            checks["ordinaryAgentStillExecutesAfterPluginLifecycle"] = try !ordinaryRead.failed && ordinaryRead.text.contains(firstSourceLine) && service.profile(ordinary.id).instructions == ordinary.instructions && Data(contentsOf: config) == originalConfig
            try plugins.setEnabled(plugins.installation(installed.id), false)
            let ui = tasks.create(title: "插件 Agent 安装验收", workspace: workspace.path, mode: .ask, workMode: .general)
            tasks.update(ui) { $0.draft = "保留插件安装验收草稿" }; tasks.selectedID = ui
            checks["noModelRequestReceiptOrAssistantReplyCreated"] = requests == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains { $0.role == "assistant" } != true }
            report["uiTaskID"] = ui; report["readerID"] = readerID; report["checkedTaskID"] = id; report["ordinaryAgentID"] = ordinary.id; report["sourceHash"] = try AgentFiles(workspace: workspace.path).fileHash(workspace.appendingPathComponent("source.txt"))
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["blockedModelAttempts"] = requests
        report["backgroundComponentCheck"] = usesBackgroundAttachmentCheck; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["scope"] = "Actual ZIP import, stored plugin definitions and model overrides, native role task, real file tools and lifecycle boundaries. No AI reply or actual window interaction is substituted."
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("plugin-agent-result.json"), options: .atomic)
    }
}
