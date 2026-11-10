import AppKit
import Darwin

@MainActor extension AppDelegate {
    private func pluginUpdateHashes(_ root: URL) throws -> [String: String] {
        let files = try AgentFiles(workspace: root.path)
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw PetError("版本目录不可读取") }
        var result: [String: String] = [:]
        while let file = iterator.nextObject() as? URL {
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true else { throw PetError("版本目录含链接") }
            if metadata.isRegularFile == true { result[files.relative(file)] = try files.fileHash(file, maximum: 2_000_000) }
        }
        return result
    }
    func runAgentPluginUpdateCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], attempts = 0
        func call(_ name: String, _ values: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)) }
        func waitUntil(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while !test() && Date() < end { await wait(0.03) }; return test() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("插件更新原生检查禁止模型请求") }
            let plugins = tasks.extensions.plugins, workspace = output.appendingPathComponent("real project"), package1 = try await plugins.inspect(output.appendingPathComponent("lifecycle-v1.zip")), package2 = try await plugins.inspect(output.appendingPathComponent("lifecycle-v2.zip"))
            let first = try plugins.install(package1); try plugins.setEnabled(first, true)
            var current = try plugins.installation(first.id)
            let reader = try tasks.agents.packagedProfiles().first { $0.name == "lifecycle-tools:reviewer" }!
            try tasks.agents.savePluginModel(reader, model: "native-version-model", expectedHash: tasks.agents.pluginModelVersion())
            let roleID = try tasks.agents.createTask(reader.id, store: tasks, workspace: workspace.path, workMode: .general)
            tasks.update(roleID) { $0.draft = "保留旧版本角色草稿" }
            let roleFile = tasks.directory.appendingPathComponent(roleID + ".json")
            let skill = try tasks.extensions.catalog(workspace: workspace.path).first { $0.name == "lifecycle-tools:source" }!
            let hookReference = try plugins.hookReferences().first { $0.name == first.id }!
            let hookDoc = try tasks.hooks.pluginDocument(hookReference)
            try tasks.hooks.savePluginDocument(hookDoc.text, reference: hookReference, original: hookDoc.original, expectedHash: hookDoc.hash)
            let hook = try tasks.hooks.catalog(workspace: workspace.path).first { $0.plugin?.name == first.id }!
            try tasks.hooks.setEnabled(hook, true, workspace: workspace.path)
            var server = tasks.mcp.servers.first { $0.plugin?.name == first.id }!
            var configuration = try JSONSerialization.jsonObject(with: Data(tasks.mcp.document(server).utf8)) as! [String: Any]
            configuration["env"] = ["RESOURCE_PATH": workspace.appendingPathComponent("source.txt").path]
            server = try tasks.mcp.save(String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self), id: server.id, expectedRevision: server.revision)
            try tasks.mcp.setEnabled(server.id, true); server = try tasks.mcp.server(server.id)
            let localFiles = [store.directory.appendingPathComponent("extensions/plugin-agent-models.json"), store.directory.appendingPathComponent("extensions/mcp.json"), store.directory.appendingPathComponent("extensions/hook-settings.json"), try plugins.hookConfiguration(hookReference).file]
            let before = try pluginUpdateHashes(current.root)
            let parent = current.root.deletingLastPathComponent(); try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            do { _ = try plugins.update(package2, replacing: current); checks["actualReadonlyParentPreventsPublication"] = false }
            catch { checks["actualReadonlyParentPreventsPublication"] = try pluginUpdateHashes(current.root) == before }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let wrong = try await plugins.inspect(output.appendingPathComponent("other-plugin.zip"))
            do { _ = try plugins.update(wrong, replacing: current); checks["differentPluginCannotReplaceReviewedInstallation"] = false }
            catch { checks["differentPluginCannotReplaceReviewedInstallation"] = try pluginUpdateHashes(current.root) == before }
            let stale = current; try plugins.setEnabled(current, false); current = try plugins.installation(first.id)
            do { _ = try plugins.update(package2, replacing: stale); checks["staleReviewCannotReplaceChangedState"] = false }
            catch { checks["staleReviewCannotReplaceChangedState"] = try plugins.installation(first.id).receiptHash == current.receiptHash }
            try plugins.setEnabled(current, true); current = try plugins.installation(first.id)
            try tasks.agents.configureDraft(reader.id, taskID: roleID, store: tasks)
            _ = try tasks.agents.currentProfile(tasks.task(roleID)!.agent!.profile)
            let freshHook = try tasks.hooks.catalog(workspace: workspace.path).first { $0.plugin?.name == first.id }!
            try tasks.hooks.setEnabled(freshHook, true, workspace: workspace.path)
            var oldRule = try plugins.ruleItems().first { $0.reference.name == first.id }!.reference; oldRule.workspace = workspace.path
            let ruleTask = tasks.create(title: "旧版本规则绑定", workspace: workspace.path, mode: .ask, workMode: .general)
            try plugins.activateRule(oldRule, store: tasks, taskID: ruleTask)
            checks["oldRoleAndRuleBindingsAreValidBeforeActualUpdate"] = try plugins.ruleContext(tasks.task(ruleTask)!).text.contains("PLUGIN_RULE_VERSION_1")
            let roleBytes = try Data(contentsOf: roleFile)
            let localBytes = try Dictionary(uniqueKeysWithValues: localFiles.map { ($0.path, try Data(contentsOf: $0)) })
            func localConfigurationUnchanged() throws -> Bool { try localBytes.allSatisfy { try Data(contentsOf: URL(fileURLWithPath: $0.key)) == $0.value } }
            let slow = tasks.create(title: "插件更新取消实际执行", workspace: workspace.path, mode: .agent, workMode: .general)
            guard runtime.submit("/skill:lifecycle-tools:source 核对实际命令取消。", taskID: slow, startImmediately: false) else { throw PetError(runtime.submissionError ?? "Skill 未保存") }
            let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8)
            let pending = try call("run_command", ["command": "'" + node.replacingOccurrences(of: "'", with: "'\\''") + "' slow.cjs", "timeout_seconds": 40, "network": false])
            tasks.update(slow) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(slow)
            let pidFile = workspace.appendingPathComponent("slow-pids.json")
            guard await waitUntil({ FileManager.default.fileExists(atPath: pidFile.path) && runtime.isRunning(slow) }), let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as? [String: Int], let parentPID = pids["pid"], let childPID = pids["child"] else { throw PetError("实际执行进程尚未启动") }
            server = try tasks.mcp.server(server.id); let owner = "plugin-update-native"
            _ = try await tasks.mcp.connect(server.id, revision: server.revision, owner: owner, workspace: workspace.path)
            guard let token = tasks.mcp.token(server.id, owner: owner), let mcpPID = await tasks.mcp.processID(server.id, owner: owner) else { throw PetError("实际插件连接未启动") }
            let catalog = try tasks.mcp.catalog(server.id, owner: owner, token: token, offset: 0, query: "read_source")
            checks["actualConnectorSchemaIsReadBeforeToolCall"] = (catalog["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "read_source" && $0["inputSchema"] is [String: Any] } == true
            let actual = try await tasks.mcp.call(server.id, owner: owner, token: token, name: "read_source", arguments: [:])
            let sourceHash = AgentFiles.hash(try Data(contentsOf: workspace.appendingPathComponent("source.txt")))
            checks["actualOldConnectorReadsPublicSourceAndVersion"] = !actual.failed && actual.text.contains(sourceHash) && actual.text.contains("version-1")
            let oldRoot = try pluginUpdateHashes(current.root), oldInstance = current.instanceID, oldActivation = current.receipt.activationID
            let updated = try plugins.update(package2, replacing: current)
            checks["actualUpdatePublishesAllNewResourcesTogetherAndStartsDisabled"] = !updated.receipt.enabled && updated.metadata.version == "2.0.0" && updated.receipt.hashes == package2.receipt.hashes && updated.instanceID != oldInstance && updated.receipt.activationID != oldActivation
            checks["actualOldTaskAndCommandChildrenStopOnUpdate"] = await waitUntil { !runtime.isRunning(slow) && kill(pid_t(parentPID), 0) != 0 && kill(pid_t(childPID), 0) != 0 && kill(mcpPID, 0) != 0 }
            report["actualCancelledPIDs"] = [parentPID, childPID, Int(mcpPID)]
            guard let revision = updated.receipt.revisions?.last else { throw PetError("原版本没有保留") }
            let saved = try plugins.revision(revision, of: updated)
            checks["previousReceiptAndEveryPayloadFileRemainOriginalBytes"] = try pluginUpdateHashes(saved.root) == oldRoot && saved.receiptHash == current.receiptHash && saved.instanceID == oldInstance
            checks["oldTaskAndLocalConfigurationAreNotRewritten"] = try Data(contentsOf: roleFile) == roleBytes && localConfigurationUnchanged()
            checks["oldConnectorTokenAndIDCannotBeReused"] = tasks.mcp.token(server.id, owner: owner) == nil && tasks.mcp.servers.first { $0.plugin?.name == first.id }?.id != server.id
            let count = updated.receipt.revisions?.count
            do { _ = try plugins.update(package2, replacing: current); checks["retryOfAlreadyAppliedReviewCannotCreateAnotherVersion"] = false }
            catch { checks["retryOfAlreadyAppliedReviewCannotCreateAnotherVersion"] = try plugins.installation(first.id).receiptHash == updated.receiptHash && plugins.installation(first.id).receipt.revisions?.count == count }
            do { _ = try plugins.update(package2, replacing: updated); checks["identicalContentsDoNotCreateAnotherVersion"] = false }
            catch { checks["identicalContentsDoNotCreateAnotherVersion"] = try plugins.installation(first.id).receiptHash == updated.receiptHash }
            try plugins.setEnabled(updated, true); let active2 = try plugins.installation(first.id)
            let skill2 = try tasks.extensions.catalog(workspace: workspace.path).first { $0.name == "lifecycle-tools:source" }!
            checks["newVersionUsesFreshExtensionIDsEvenForUnchangedInstructions"] = skill2.id != skill.id && skill2.sha256 == skill.sha256
            do { _ = try runtime.systemContext(tasks.task(slow)!); checks["queuedOrStoppedOldSkillCannotSilentlyResume"] = false } catch { checks["queuedOrStoppedOldSkillCannotSilentlyResume"] = error.localizedDescription.contains("扩展") }
            do { _ = try tasks.agents.currentProfile(tasks.task(roleID)!.agent!.profile); checks["oldRoleBindingCannotUseEnabledNewVersion"] = false } catch { checks["oldRoleBindingCannotUseEnabledNewVersion"] = true }
            let ruleProbe = tasks.create(title: "旧规则不能激活新版本", workspace: workspace.path, mode: .ask, workMode: .general)
            do { try plugins.activateRule(oldRule, store: tasks, taskID: ruleProbe); checks["oldRuleBindingCannotUseEnabledNewVersion"] = false } catch { checks["oldRuleBindingCannotUseEnabledNewVersion"] = true }
            do { _ = try plugins.hookConfiguration(hookReference); checks["oldHookConfigurationCannotAuthorizeNewVersion"] = false } catch { checks["oldHookConfigurationCannotAuthorizeNewVersion"] = true }
            let newServer = tasks.mcp.servers.first { $0.plugin?.name == first.id }!
            checks["newConnectorRequiresFreshConfigurationWithoutReusingOldValues"] = newServer.configured == false && !newServer.enabled
            let fresh = tasks.create(title: "新版本实际Skill资源", workspace: workspace.path, mode: .ask, workMode: .general)
            guard runtime.submit("/skill:lifecycle-tools:source 读取当前资源。", taskID: fresh, startImmediately: false) else { throw PetError(runtime.submissionError ?? "新 Skill 未保存") }
            let read = try await AgentTools(store: tasks, taskID: fresh).execute(call("read_skill_resource", ["id": skill2.id, "path": "resources/version.json"]))
            checks["freshSelectionReadsActualNewVersionResource"] = !read.failed && read.text.contains("version-2")
            let v2Bytes = try pluginUpdateHashes(active2.root), recoveryPackage = try plugins.package(revision, of: active2)
            let restored = try plugins.update(recoveryPackage, replacing: active2)
            checks["restoreUsesOriginalPayloadButFreshDisabledIdentity"] = restored.metadata.version == "1.0.0" && restored.receipt.hashes == package1.receipt.hashes && !restored.receipt.enabled && restored.instanceID != oldInstance && restored.instanceID != active2.instanceID
            guard let v2Revision = restored.receipt.revisions?.last else { throw PetError("被恢复前的版本丢失") }
            checks["restorationAlsoRetainsTheReplacedNewVersion"] = try pluginUpdateHashes(plugins.revision(v2Revision, of: restored).root) == v2Bytes
            try plugins.setEnabled(restored, true); let enabledRestored = try plugins.installation(first.id)
            do { _ = try tasks.agents.currentProfile(tasks.task(roleID)!.agent!.profile); checks["restoringSamePayloadDoesNotResurrectOriginalRoleApproval"] = false } catch { checks["restoringSamePayloadDoesNotResurrectOriginalRoleApproval"] = true }
            checks["restoringSamePayloadDoesNotResurrectOriginalExtensionID"] = try tasks.extensions.catalog(workspace: workspace.path).first { $0.name == "lifecycle-tools:source" }?.id != skill.id
            checks["localConfigurationAndOldTaskBytesSurviveRestoreAndReenable"] = try localConfigurationUnchanged() && Data(contentsOf: roleFile) == roleBytes
            let oldSnapshotFile = saved.root.appendingPathComponent("payload/README.md"), savedBytes = try Data(contentsOf: oldSnapshotFile)
            try Data("Actual external edit to retained snapshot\n".utf8).write(to: oldSnapshotFile, options: .atomic)
            do { _ = try plugins.package(revision, of: enabledRestored); checks["modifiedHistoryCannotBeRestoredAsReviewedOriginal"] = false } catch { checks["modifiedHistoryCannotBeRestoredAsReviewedOriginal"] = true }
            try savedBytes.write(to: oldSnapshotFile, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: oldSnapshotFile.path)
            let reloaded = AgentPlugins(profile: store.directory)
            checks["currentVersionAndHistoryLoadIntoFreshService"] = try reloaded.installation(first.id).receiptHash == enabledRestored.receiptHash && reloaded.revision(revision, of: reloaded.installation(first.id)).metadata.version == "1.0.0"
            try plugins.setEnabled(enabledRestored, false)
            checks["noActualModelReceiptOrAssistantReplyCreated"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains(where: \.isReply) != true }
            report["sourceHash"] = sourceHash; report["pluginName"] = first.id; report["finalReceiptHash"] = try plugins.installation(first.id).receiptHash; report["roleTaskID"] = roleID; report["slowTaskID"] = slow
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let file = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: file.deletingLastPathComponent().path).fileHash(file) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-update-result.json"), options: .atomic)
    }
    func runAgentPluginUpdateCrashCheck(_ output: URL) async {
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
            agentRuntime?.modelRequestCheck = { throw PetError("中断验收禁止模型请求") }
            let plugins = tasks.extensions.plugins, current = try plugins.installation("lifecycle-tools"), before = try pluginUpdateHashes(current.root), package = try await plugins.inspect(output.appendingPathComponent("lifecycle-v2.zip"))
            let existing = Set(try FileManager.default.contentsOfDirectory(atPath: current.root.deletingLastPathComponent().path))
            _ = try plugins.update(package, replacing: current) {
                let added = Set(try FileManager.default.contentsOfDirectory(atPath: current.root.deletingLastPathComponent().path)).subtracting(existing).filter { $0.hasPrefix(".plugin-revision-") }
                guard added.count == 1, let name = added.first else { throw PetError("没有找到实际已准备的候选") }
                let marker: [String: Any] = ["appPID": getpid(), "currentReceiptHash": current.receiptHash, "visibleFiles": before, "unpublishedDirectory": name]
                try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-update-crash-prepared.json"), options: .atomic)
                while true { Darwin.sleep(1) }
            }
        } catch { try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]).write(to: output.appendingPathComponent("plugin-update-crash-error.json")) }
    }
    func runAgentPluginUpdateRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
            agentRuntime?.modelRequestCheck = { throw PetError("恢复验收禁止模型请求") }
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("plugin-update-crash-prepared.json"))) as! [String: Any], oldPID = marker["appPID"] as! Int
            guard kill(pid_t(oldPID), 0) != 0, let before = marker["visibleFiles"] as? [String: String], let directory = marker["unpublishedDirectory"] as? String else { throw PetError("原中断进程尚未结束") }
            let plugins = tasks.extensions.plugins, current = try plugins.installation("lifecycle-tools")
            checks["actualKilledUpdateLeavesVisibleVersionOriginalBytes"] = try current.receiptHash == marker["currentReceiptHash"] as? String && pluginUpdateHashes(current.root) == before
            let unpublished = current.root.deletingLastPathComponent().appendingPathComponent(directory)
            _ = try plugins.catalog()
            checks["unpublishedCandidateIsRetainedAndReportedWithoutActivation"] = FileManager.default.fileExists(atPath: unpublished.path) && current.receipt.revisions?.contains(where: { $0.directory == directory }) != true && plugins.warnings.contains { $0.contains("未关联") }
            let candidateBefore = try pluginUpdateHashes(unpublished), package = try await plugins.inspect(output.appendingPathComponent("lifecycle-v2.zip")), updated = try plugins.update(package, replacing: current)
            checks["freshReviewAfterCrashCanPublishWithoutLosingEitherCopy"] = try updated.metadata.version == "2.0.0" && !updated.receipt.enabled && pluginUpdateHashes(unpublished) == candidateBefore && updated.receipt.revisions?.last.map { try pluginUpdateHashes(plugins.revision($0, of: updated).root) == before } == true
            checks["noModelReceiptsWereAddedByRecovery"] = tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false }
            report["currentReceiptHash"] = updated.receiptHash; report["unpublishedDirectory"] = directory
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["modelRequests"] = 0; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let file = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: file.deletingLastPathComponent().path).fileHash(file) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-update-recovery-result.json"), options: .atomic)
    }
}
