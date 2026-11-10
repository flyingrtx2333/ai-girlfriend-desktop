import AppKit
import Darwin

@MainActor extension AppDelegate {
    func checkAgentPluginSettings(_ output: URL, tasks: AgentStore, runtime: AgentRuntime, a: String, b: String) async throws -> [String: Bool] {
        let plugins = tasks.extensions.plugins, name = "lifecycle-tools", id = "lifecycle-tools@local", aID = AgentPlugins.scopedID(name, workspace: a)
        var checks: [String: Bool] = [:]
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-settings-native-checks.json"), options: .atomic) }
        func setting(_ value: Bool?, _ scope: AgentPluginSettingScope, _ workspace: String?) throws {
            let document = try plugins.settingDocument(scope, workspace: workspace)
            try plugins.setPluginSetting(value, name: name, scope: scope, workspace: workspace, expectedHash: document.hash)
        }
        func userEnabled(_ workspace: String?) throws -> Bool { try plugins.catalog(workspace: workspace).first { $0.id == name }?.enabled == true }
        let user = try plugins.installation(name), userBytes = try pluginUpdateHashes(user.root), originalA = try plugins.installation(aID), projectBytes = try pluginUpdateHashes(originalA.root)
        var doc = try plugins.settingDocument(.user, workspace: nil), object = doc.object
        object["unrelated"] = ["keep": [1, true, ["text": "保留"]] as [Any]]; object["hooks"] = [:] as [String: Any]
        try doc.files.writeData(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: doc.file, permissions: 0o600)
        try setting(false, .user, nil)
        checks["actualUserFileDisablesUserPackageInAllProjectsAndWithoutWorkspace"] = try !userEnabled(nil) && !userEnabled(b)
        try setting(true, .project, b)
        checks["projectSettingOverridesUserOnlyInExactProject"] = try userEnabled(b) && !userEnabled(nil) && plugins.pluginSelection(name, workspace: b)?.scope == .project
        try setting(false, .local, b)
        checks["localFalseOverridesProjectTrue"] = try !userEnabled(b) && plugins.settingDocument(.project, workspace: b).values[id] == true
        try setting(nil, .local, b)
        checks["removingLocalEntryInheritsProjectValue"] = try userEnabled(b) && plugins.settingDocument(.local, workspace: b).values[id] == nil
        try setting(nil, .project, b)
        checks["removingProjectEntryInheritsUserValue"] = try !userEnabled(b) && plugins.pluginSelection(name, workspace: b)?.scope == .user
        try setting(true, .user, nil)
        doc = try plugins.settingDocument(.user, workspace: nil)
        checks["writesPreserveUnknownNestedFieldsAndHookDeclarations"] = (doc.object["unrelated"] as? NSDictionary) == (object["unrelated"] as? NSDictionary) && (doc.object["hooks"] as? NSDictionary) == (object["hooks"] as? NSDictionary)
        let skill = try tasks.extensions.catalog(workspace: b).first { $0.kind == .skill }!, role = try tasks.agents.list(workspace: b).first { $0.pluginSource != nil }!, rule = try plugins.ruleItems(workspace: b).first!, connector = tasks.mcp.availableServers(workspace: b).first { $0.plugin != nil }!
        let skillTask = tasks.create(title: "配置停用后的真实Skill绑定", workspace: b, mode: .ask, workMode: .general), commandTask = tasks.create(title: "配置停用后的真实命令绑定", workspace: b, mode: .ask, workMode: .general)
        guard runtime.submit("/skill:lifecycle-tools:source 保留原任务", taskID: skillTask, startImmediately: false), runtime.submit("/command:lifecycle-tools:inspect 保留原输入", taskID: commandTask, startImmediately: false) else { throw PetError("设置验收的扩展输入未保存") }
        try setting(false, .project, b)
        checks["effectiveSelectionDisablesSkillCommandAgentRuleMCPAndHookTogether"] = try tasks.extensions.catalog(workspace: b, includeDisabled: false).isEmpty && tasks.agents.list(workspace: b).filter { $0.pluginSource != nil }.allSatisfy { !$0.enabled } && plugins.ruleItems(workspace: b).allSatisfy { !$0.enabled } && tasks.mcp.availableServers(workspace: b).filter { $0.plugin != nil }.allSatisfy { !$0.enabled && $0.pluginEnabled == false } && tasks.hooks.catalog(workspace: b).filter { $0.plugin != nil }.allSatisfy { $0.pluginEnabled == false }
        do { _ = try runtime.systemContext(tasks.task(skillTask)!); checks["savedSkillCannotBypassProjectDisable"] = false } catch { checks["savedSkillCannotBypassProjectDisable"] = true }
        do { _ = try runtime.systemContext(tasks.task(commandTask)!); checks["savedCommandCannotBypassProjectDisable"] = false } catch { checks["savedCommandCannotBypassProjectDisable"] = true }
        do { try plugins.validateAgent(role.pluginSource!, workspace: b); checks["savedRoleCannotBypassProjectDisable"] = false } catch { checks["savedRoleCannotBypassProjectDisable"] = true }
        do { try plugins.validateMCP(connector.plugin!, workspace: b); checks["savedConnectorCannotBypassProjectDisable"] = false } catch { checks["savedConnectorCannotBypassProjectDisable"] = true }
        do { _ = try plugins.currentRule(rule.id, workspace: b); checks["savedRuleCannotBypassProjectDisable"] = false } catch { checks["savedRuleCannotBypassProjectDisable"] = true }
        let hookResult = try await tasks.hooks.fire(.sessionStart, trigger: "disabled-by-project-setting", store: tasks, taskID: skillTask)
        checks["disabledSharedHookDoesNotExecuteItsActualProgram"] = !hookResult.context.contains("actual plugin source version")
        try setting(nil, .project, b)
        checks["restoringInheritanceRetainsActualSkillIdentity"] = try tasks.extensions.item(skill.id, workspace: b).enabled
        try plugins.setEnabled(try plugins.installation(aID), true)
        let before = try plugins.installation(aID), oldRole = try tasks.agents.list(workspace: a).first { $0.pluginSource != nil }!, oldRule = try plugins.ruleItems(workspace: a).first!
        let ruleTask = tasks.create(title: "原项目规则绑定", workspace: a, mode: .ask, workMode: .general)
        var oldRuleReference = oldRule.reference; oldRuleReference.workspace = a
        try plugins.validateAgent(oldRole.pluginSource!, workspace: a); try plugins.activateRule(oldRuleReference, store: tasks, taskID: ruleTask)
        checks["roleAndRuleBindingsActuallyWorkBeforePrivateEpochChanges"] = tasks.task(ruleTask)?.activeRules?.contains(oldRuleReference) == true
        try plugins.setEnabled(before, false); try plugins.setEnabled(plugins.installation(aID), true)
        let after = try plugins.installation(aID)
        checks["localActivationNeverRewritesSharedReceiptOrPayload"] = try pluginUpdateHashes(after.root) == projectBytes && after.enabled && after.receiptHash == before.receiptHash && after.activationID != before.activationID
        checks["localActivationIsWrittenOnlyToProjectLocalSettings"] = try plugins.settingDocument(.local, workspace: a).values[id] == true && plugins.settingDocument(.project, workspace: a).values[id] == nil
        do { try plugins.validateAgent(oldRole.pluginSource!, workspace: a); checks["privateActivationEpochRejectsOldRoleBinding"] = false } catch { checks["privateActivationEpochRejectsOldRoleBinding"] = true }
        do { try plugins.activateRule(oldRuleReference, store: tasks, taskID: ruleTask); checks["privateActivationEpochRejectsOldRuleBinding"] = false } catch { checks["privateActivationEpochRejectsOldRuleBinding"] = true }
        try setting(true, .project, a); try setting(nil, .local, a)
        let changed = try plugins.installation(aID)
        checks["changingEffectiveDeclarationRevokesLocalApprovalBeforeUse"] = !changed.enabled && changed.locallyReviewed && !plugins.hasProjectActivations(a)
        try plugins.setEnabled(changed, true)
        checks["reviewOfSharedTrueDoesNotCreateLocalOverride"] = try plugins.installation(aID).enabled && plugins.settingDocument(.local, workspace: a).values[id] == nil
        let c = output.appendingPathComponent("copied project"), sharedDocument = try plugins.settingDocument(.project, workspace: a), copyFiles = try AgentFiles(workspace: c.path)
        try copyFiles.writeData(sharedDocument.files.readData(sharedDocument.file, maximum: 512_000), to: copyFiles.literalURL(".qoder/settings.json"), permissions: 0o644)
        checks["actualSharedDeclarationCannotAuthorizeAnotherProjectCopy"] = try plugins.pluginSelection(name, workspace: c.path)?.enabled == true && !plugins.catalog(workspace: c.path, onlyScope: true).first!.enabled && plugins.catalog(workspace: c.path).first?.id == name
        let stale = try plugins.settingDocument(.project, workspace: a)
        let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8), writer = Process()
        writer.executableURL = URL(fileURLWithPath: node); writer.arguments = ["-e", "const fs=require('fs');const p=process.argv[1];const x=JSON.parse(fs.readFileSync(p,'utf8'));x.externalWriter='keep actual external update';fs.writeFileSync(p,JSON.stringify(x));", stale.file.path]
        try writer.run(); let writerPID = writer.processIdentifier; writer.waitUntilExit(); guard writer.terminationStatus == 0 else { throw PetError("独立配置写入进程失败") }
        let external = try stale.files.readData(stale.file, maximum: 512_000)
        do { try plugins.setPluginSetting(false, name: name, scope: .project, workspace: a, expectedHash: stale.hash); checks["actualIndependentWriterCannotBeOverwrittenByStaleEditor"] = false } catch { checks["actualIndependentWriterCannotBeOverwrittenByStaleEditor"] = try stale.files.readData(stale.file, maximum: 512_000) == external }
        try JSONSerialization.data(withJSONObject: ["PID": writerPID, "exitCode": writer.terminationStatus, "fileHash": AgentFiles.hash(external)]).write(to: output.appendingPathComponent("plugin-setting-independent-writer.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stale.file.path)
        do { try setting(false, .project, a); checks["readonlyDeclarationIsPreservedWithoutReplacement"] = false } catch { checks["readonlyDeclarationIsPreservedWithoutReplacement"] = try stale.files.readData(stale.file, maximum: 512_000) == external }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stale.file.path)
        let local = try plugins.settingDocument(.local, workspace: a), localBytes = try local.files.readData(local.file, maximum: 512_000)
        let outside = output.appendingPathComponent("outside-plugin-settings.json"), outsideBytes = Data("{\"enabledPlugins\":{\"lifecycle-tools@local\":true}}".utf8)
        try outsideBytes.write(to: outside); try FileManager.default.removeItem(at: local.file); try FileManager.default.createSymbolicLink(at: local.file, withDestinationURL: outside)
        do { _ = try plugins.pluginSelection(name, workspace: a); checks["settingsSymlinkCannotReadOutsideProject"] = false } catch { checks["settingsSymlinkCannotReadOutsideProject"] = true }
        do { try plugins.setPluginSetting(false, name: name, scope: .local, workspace: a, expectedHash: nil); checks["settingsSymlinkCannotRewriteOutsideProject"] = false } catch { checks["settingsSymlinkCannotRewriteOutsideProject"] = try Data(contentsOf: outside) == outsideBytes }
        try FileManager.default.removeItem(at: local.file); try local.files.writeData(localBytes, to: local.file, permissions: 0o600)
        for (label, bad) in [("numericBoolean", "{\"enabledPlugins\":{\"lifecycle-tools@local\":1}}"), ("inexactID", "{\"enabledPlugins\":{\"lifecycle-tools\":true}}"), ("invalidObject", "{\"enabledPlugins\":[]}")] {
            try local.files.writeData(Data(bad.utf8), to: local.file, permissions: 0o600)
            do { _ = try plugins.pluginSelection(name, workspace: a); checks["rejectsInvalidConfiguration-" + label] = false } catch { checks["rejectsInvalidConfiguration-" + label] = true }
        }
        let invalidTask = tasks.create(title: "无效配置阻止实际上下文", workspace: a, mode: .ask, workMode: .general)
        do { _ = try runtime.systemContext(tasks.task(invalidTask)!); checks["invalidConfigurationStopsActualContextBeforeModel"] = false } catch { checks["invalidConfigurationStopsActualContextBeforeModel"] = true }
        try local.files.writeData(localBytes, to: local.file, permissions: 0o600)
        let legacy = output.appendingPathComponent("legacy actual project"), legacyProfile = output.appendingPathComponent("legacy private profile")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent(".bluefatfish/plugins"), withIntermediateDirectories: true); try FileManager.default.createDirectory(at: legacyProfile, withIntermediateDirectories: true)
        let legacyService = AgentPlugins(profile: legacyProfile), legacyID = AgentPlugins.scopedID(name, workspace: try AgentFiles(workspace: legacy.path).root.path), legacyRoot = legacy.appendingPathComponent(".bluefatfish/plugins/lifecycle-tools")
        try FileManager.default.copyItem(at: originalA.root, to: legacyRoot)
        var legacyReceipt = originalA.receipt; legacyReceipt.enabled = true
        let raw = try JSONEncoder().encode(legacyReceipt); try raw.write(to: legacyRoot.appendingPathComponent("receipt.json"), options: .atomic)
        let legacyFiles = try AgentFiles(workspace: legacyProfile.path), grant = try legacyFiles.literalURL("extensions/project-plugin-approvals.json")
        let oldGrant: [String: [String: String]] = [legacyID: ["reviewedHash": try AgentPlugins.reviewFingerprint(legacyReceipt), "activeHash": AgentFiles.hash(raw)]]
        try legacyFiles.writeData(JSONSerialization.data(withJSONObject: oldGrant, options: [.sortedKeys]), to: grant, permissions: 0o600)
        let legacyBefore = try pluginUpdateHashes(legacy), grantBefore = try Data(contentsOf: grant), legacyItem = try legacyService.installation(legacyID)
        checks["actualLegacyTwoFieldApprovalLoadsWithoutAnyRewrite"] = try legacyItem.enabled && legacyItem.localActivationID == nil && pluginUpdateHashes(legacy) == legacyBefore && Data(contentsOf: grant) == grantBefore
        try legacyService.setEnabled(legacyItem, false)
        checks["legacyDisableAddsLocalChoiceAndPreservesOriginalPackageBytes"] = try !legacyService.installation(legacyID).enabled && Data(contentsOf: legacyRoot.appendingPathComponent("receipt.json")) == raw
        try grantBefore.write(to: grant, options: .atomic)
        checks["replayedLegacyApprovalCannotOverrideNewLocalFalse"] = try !legacyService.installation(legacyID).enabled
        let retired = output.appendingPathComponent("retired actual project"), held = output.appendingPathComponent("held disconnected project")
        try FileManager.default.createDirectory(at: retired.appendingPathComponent(".bluefatfish/plugins"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: originalA.root, to: retired.appendingPathComponent(".bluefatfish/plugins/lifecycle-tools"))
        let retiredID = AgentPlugins.scopedID(name, workspace: try AgentFiles(workspace: retired.path).root.path)
        try plugins.recordProjectReview(plugins.installation(retiredID), active: true)
        try FileManager.default.moveItem(at: retired, to: held)
        try setting(false, .user, nil)
        checks["actualUnavailableProjectCannotBlockUserSettingOrKeepApproval"] = try !userEnabled(nil) && plugins.projectApprovals()[retiredID]?.activeHash == nil && FileManager.default.fileExists(atPath: held.path)
        try setting(true, .user, nil)
        checks["allSettingsOperationsPreserveUserAndProjectPayloadHistoryBytes"] = try pluginUpdateHashes(user.root) == userBytes && pluginUpdateHashes(originalA.root) == projectBytes
        return checks
    }
}
