import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentPluginHookCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        func waitUntil(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(8); while !test() && Date() < end { await wait(0.03) }; return test() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("插件 Hooks 原生检查禁止模型请求") }
            let service = tasks.hooks, plugins = tasks.extensions.plugins, workspace = output.appendingPathComponent("real project")
            let source = try Data(contentsOf: workspace.appendingPathComponent("source.txt")), sourceHash = AgentFiles.hash(source)
            let package = try await plugins.inspect(output.appendingPathComponent("native-hooks.zip")), installed = try plugins.install(package)
            let refs = try plugins.hookReferences().filter { $0.name == installed.id }; guard refs.count == 1 else { throw PetError("插件 Hooks 来源数量不符") }; let reference = refs[0]
            func hook(_ suffix: String) throws -> AgentHookDefinition {
                guard let item = try service.catalog(workspace: workspace.path).first(where: { $0.name == installed.id + ":" + suffix }) else { throw PetError("没有找到插件 Hook：" + suffix) }; return item
            }
            func fire(_ event: AgentHookEvent, id: String, trigger: String, value: String = "", fields: [String: Any] = [:]) async throws -> AgentHookEffect { try await service.fire(event, trigger: trigger, store: tasks, taskID: id, value: value, fields: fields) }
            let initial = try service.catalog(workspace: workspace.path).filter { $0.plugin?.name == installed.id }
            let managedFile = try plugins.hookConfiguration(reference).file
            checks["hookOnlyPackageDiscoversAllFourHandlerTypes"] = installed.receipt.components.isEmpty && installed.agents.isEmpty && installed.mcpServers.isEmpty && initial.count == 7 && Set(initial.map(\.type)) == ["command", "http", "prompt", "agent"]
            checks["importDoesNotConfigureEnableOrExecuteHandlers"] = initial.allSatisfy { !service.enabled($0) && $0.diagnostic != nil && $0.pluginEnabled == false } && !fm.fileExists(atPath: managedFile.path)
            let doc = try service.pluginDocument(reference)
            try service.savePluginDocument(doc.text, reference: reference, original: doc.original, expectedHash: doc.hash)
            let config = try plugins.hookConfiguration(reference), configured = try Data(contentsOf: config.file)
            checks["localConfigurationPreservesReadonlyPackage"] = try installed.receipt.hashes.allSatisfy { path, hash in (try? plugins.content(path, installation: plugins.installation(installed.id))).map(AgentFiles.hash) == hash } && (fm.attributesOfItem(atPath: config.file.path)[.posixPermissions] as? Int) == 0o600
            checks["savedEnvironmentAndHeadersUseKeychainPlaceholders"] = !String(decoding: configured, as: UTF8.self).contains("public-plugin-marker") && !String(decoding: configured, as: UTF8.self).contains("public-plugin-header") && String(decoding: configured, as: UTF8.self).contains("${KEYCHAIN}")
            do { try service.setEnabled(hook("source"), true, workspace: workspace.path); checks["handlerCannotBypassDisabledParent"] = false } catch { checks["handlerCannotBypassDisabledParent"] = true }
            try plugins.setEnabled(installed, true)
            for name in ["source", "shell-root", "conditional-block", "local-http", "slow"] { try service.setEnabled(hook(name), true, workspace: workspace.path) }
            let id = tasks.create(title: "插件 Hooks 实际读取", workspace: workspace.path, mode: .agent, workMode: .general)
            tasks.update(id) { $0.draft = "保留插件处理器草稿"; $0.hookSession = UUID().uuidString }
            let effect = try await fire(.sessionStart, id: id, trigger: "source")
            checks["actualExecReadsProjectAndPackagedResourceHashes"] = effect.context.contains(sourceHash) && effect.context.contains("rootOK=true") && tasks.task(id)?.events.last?.hook?.exitCode == 0
            checks["actualCommandEnvironmentIsRedactedFromStoredOutput"] = !effect.context.contains("public-plugin-marker") && tasks.task(id)?.events.last?.detail.contains("public-plugin-marker") == false
            let shell = try await fire(.instructions, id: id, trigger: "shell")
            checks["actualShellUsesQuotedPluginRootWithSpaces"] = output.path.contains(" ") && shell.context.contains(sourceHash) && shell.context.contains("rootOK=true")
            let eventCount = tasks.task(id)!.events.count
            _ = try await fire(.preTool, id: id, trigger: "skip", value: "Read", fields: ["tool_name": "Read", "tool_input": ["path": "source.txt"]])
            checks["conditionSkipsNonmatchingActualToolInput"] = tasks.task(id)?.events.count == eventCount
            let blocked = try await fire(.preTool, id: id, trigger: "blocked", value: "Read", fields: ["tool_name": "Read", "tool_input": ["path": "blocked.txt"]])
            checks["actualExitTwoStillBlocksMatchingTool"] = blocked.deny?.contains("plugin policy blocked") == true && tasks.task(id)?.events.last?.hook?.exitCode == 2
            let http = try await fire(.notification, id: id, trigger: "http")
            checks["realLocalHTTPReceivesCredentialAndReturnsActualFileHash"] = http.context.contains("http.source=" + sourceHash) && !http.context.contains("public-plugin-header")
            let httpLog = try String(contentsOf: output.appendingPathComponent("http-requests.jsonl"), encoding: .utf8)
            checks["independentServerConfirmsActualHeaderAndEvent"] = httpLog.contains("\"headerMatched\":true") && httpLog.contains("Notification") && httpLog.contains(sourceHash)
            let currentDoc = try service.pluginDocument(reference)
            let changedProgram = currentDoc.text.replacingOccurrences(of: "runner.cjs", with: "other-program.cjs")
            do { try service.savePluginDocument(changedProgram, reference: reference, original: currentDoc.original, expectedHash: currentDoc.hash); checks["localEditorCannotChangeManagedProgram"] = false } catch { checks["localEditorCannotChangeManagedProgram"] = try Data(contentsOf: config.file) == configured }
            do { try service.savePluginDocument(currentDoc.text, reference: reference, original: currentDoc.original, expectedHash: nil); checks["staleLocalEditorCannotOverwriteConfiguration"] = false } catch { checks["staleLocalEditorCannotOverwriteConfiguration"] = true }
            var edited = try JSONSerialization.jsonObject(with: Data(currentDoc.text.utf8)) as! [String: Any], events = edited["hooks"] as! [String: Any], groups = events["SessionStart"] as! [[String: Any]], handlers = groups[0]["hooks"] as! [[String: Any]]
            handlers[0]["env"] = ["PUBLIC_MARKER": "public-plugin-marker-updated"]; groups[0]["hooks"] = handlers; events["SessionStart"] = groups; edited["hooks"] = events
            let text = String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self)
            try service.savePluginDocument(text, reference: reference, original: currentDoc.original, expectedHash: currentDoc.hash)
            checks["credentialChangeRevokesOnlyItsPreviousGrant"] = try !service.enabled(hook("source")) && service.trusted(hook("local-http")) && !String(decoding: Data(contentsOf: config.file), as: UTF8.self).contains("public-plugin-marker-updated")
            try service.setEnabled(hook("source"), true, workspace: workspace.path)
            let reloaded = AgentHooks(profile: store.directory, sharedHome: output.appendingPathComponent("shared-home"), keychain: PetKeychain(service: "com.xjs.bluefatfish.hooks.check." + AgentFiles.hash(Data(output.path.utf8))), plugins: plugins)
            let sourceID = try hook("source").id
            checks["configurationGrantAndKeychainSurviveServiceReload"] = try reloaded.catalog(workspace: workspace.path).contains { $0.id == sourceID && reloaded.trusted($0) && reloaded.credentials.available($0) }
            let slowOwner = tasks.create(title: "插件停用实际进程检查", workspace: workspace.path, mode: .agent, workMode: .general)
            let immediate = try await fire(.postTool, id: slowOwner, trigger: "slow")
            let pidFile = workspace.appendingPathComponent("slow-pids.json")
            let started = await waitUntil { fm.fileExists(atPath: pidFile.path) && service.isRunning(slowOwner) }
            guard started, let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as? [String: Int], let parent = pids["pid"], let child = pids["child"] else { throw PetError("真实后台父子进程尚未开始") }
            checks["actualBackgroundReturnsBeforeItsProcessFinishes"] = service.isRunning(slowOwner) && kill(pid_t(parent), 0) == 0 && kill(pid_t(child), 0) == 0 && immediate.context.isEmpty
            let old = try hook("source")
            try plugins.setEnabled(plugins.installation(installed.id), false)
            let stopped = await waitUntil { !service.isRunning(slowOwner) && kill(pid_t(parent), 0) != 0 && kill(pid_t(child), 0) != 0 }
            checks["parentDisableTerminatesActualHookAndChildProcesses"] = stopped
            checks["cancelledResultCannotEnterTaskContext"] = tasks.task(slowOwner)?.hookContexts?.isEmpty != false && tasks.task(slowOwner)?.events.last?.hook?.delivery == "cancelled"
            let before = tasks.task(id)!.events.count
            _ = try await fire(.sessionStart, id: id, trigger: "disabled")
            checks["disabledParentDoesNotRunOrBlockOtherTaskWork"] = try tasks.task(id)?.events.count == before && service.catalog(workspace: workspace.path).filter { $0.plugin?.name == installed.id }.allSatisfy { !service.enabled($0) }
            try plugins.setEnabled(plugins.installation(installed.id), true)
            checks["reenableDoesNotTrustTheOldActivation"] = try !service.trusted(hook("source"))
            do { try service.setEnabled(old, true, workspace: workspace.path); checks["oldReviewCannotAuthorizeNewActivation"] = false } catch { checks["oldReviewCannotAuthorizeNewActivation"] = true }
            try service.setEnabled(hook("source"), true, workspace: workspace.path)
            checks["explicitFreshReviewRestoresActualExecution"] = try await fire(.sessionStart, id: id, trigger: "fresh").context.contains(sourceHash)
            let resource = installed.root.appendingPathComponent("payload/resources/reference.txt"), original = try Data(contentsOf: resource)
            try Data("changed public resource".utf8).write(to: resource, options: .atomic)
            do { _ = try await fire(.sessionStart, id: id, trigger: "changed-resource"); checks["changedPackageResourceIsRejectedBeforeCommandStarts"] = false } catch { checks["changedPackageResourceIsRejectedBeforeCommandStarts"] = true; report["resourceFailure"] = error.localizedDescription }
            try original.write(to: resource, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: resource.path)
            checks["allModelHandlersRemainDisabledWithoutRequests"] = try service.catalog(workspace: workspace.path).filter { ["prompt", "agent"].contains($0.type) }.allSatisfy { !service.enabled($0) }
            for (name, key) in [("inline-hooks.zip", "inlineManifestHooksInstall"), ("array-hooks.zip", "declaredHookPathArrayInstalls")] { let inspected = try await plugins.inspect(output.appendingPathComponent(name)), item = try plugins.install(inspected); checks[key] = item.hooks.count == 1 && item.hooks[0].preview.count == 1 }
            for (name, key) in [("missing-hooks.zip", "missingDeclaredHookRejected"), ("bad-field.zip", "unsupportedHookFieldRejected"), ("bad-network.zip", "malformedNetworkCannotSilentlyBecomeAllowed"), ("reserved-env.zip", "pluginCannotOverrideItsRootVariables"), ("orphan-hooks.zip", "undeclaredHookDirectoryCannotBeSilentlyDropped")] { do { _ = try await plugins.inspect(output.appendingPathComponent(name)); checks[key] = false } catch { checks[key] = true } }
            try plugins.setEnabled(plugins.installation(installed.id), false)
            let ui = tasks.create(title: "插件 Hooks 窗口验收", workspace: workspace.path, mode: .ask, workMode: .general); tasks.update(ui) { $0.draft = "保留插件处理器原草稿" }; tasks.selectedID = ui
            checks["publicProjectSourceIsUnchanged"] = try Data(contentsOf: workspace.appendingPathComponent("source.txt")) == source
            checks["noModelRequestReceiptOrAssistantReplyWasCreated"] = requests == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains { $0.role == "assistant" } != true }
            report["sourceHash"] = sourceHash; report["actualCancelledPIDs"] = [parent, child]; report["uiTaskID"] = ui; report["checkedTaskID"] = id
        } catch { report["error"] = error.localizedDescription }
        agentStore?.hooks.cancelAll(); let end = Date().addingTimeInterval(8)
        while agentStore?.hooks.isWorking == true && Date() < end { await wait(0.03) }
        report["activeHookJobs"] = agentStore?.hooks.isWorking == true
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && agentStore?.hooks.isWorking != true
        report["appPID"] = getpid(); report["blockedModelAttempts"] = requests; report["backgroundComponentCheck"] = usesBackgroundAttachmentCheck; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["scope"] = "Actual ZIP installation, native isolated command/HTTP handlers, keychain configuration, real file hashes and cancellation of actual parent/child processes. Prompt and Agent handler loading only; no model response is substituted."
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-hook-result.json"), options: .atomic)
    }
}
