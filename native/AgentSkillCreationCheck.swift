import AppKit

@MainActor extension AppDelegate {
    private func creationCall(_ name: String, _ values: [String: Any]) throws -> AgentToolCall {
        .init(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self))
    }
    private func stageCreationFixture(_ id: String, name: String, tasks: AgentStore) throws {
        tasks.update(id) {
            $0.messages = [.init(role: "user", content: "原生公开样例：创建核对 README 的 Skill。"), .init(role: "assistant", content: "原生方案样例，非模型输出：读取实际 README，引用行号，以模板记录结果。")]
            $0.status = .completed
        }
        guard let source = AgentSkillDrafts.planSource(tasks.task(id)!) else { throw PetError("缺少原生方案") }
        try AgentSkillDrafts.approvePlan(id, source: source, store: tasks)
        let text = "---\nname: " + name + "\ndescription: Verify a public README and cite actual lines\n---\n# README check\nRead the actual README, check the requested fact and cite line numbers.\nUse templates/result.txt to record the result.\n"
        _ = try AgentSkillDrafts.stage(creationCall("draft_skill", ["path": "SKILL.md", "content": text]), taskID: id, store: tasks)
        _ = try AgentSkillDrafts.stage(creationCall("draft_skill", ["path": "templates/result.txt", "content": "Fact:\nREADME lines:\nChecked result:\n"]), taskID: id, store: tasks)
        tasks.update(id) { $0.status = .completed }
    }
    @discardableResult func prepareSkillCreationUI(_ output: URL, seed: Bool) throws -> [String: String] {
        ensureAgent(); guard let tasks = agentStore else { throw PetError("缺少 Skill 创建环境") }
        let file = output.appendingPathComponent("skill-creation-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let source = ids["source"], tasks.task(source) != nil else { throw PetError("原 Skill 创建样例不可用") }
            control.showAgentTask(source); control.show(tab: "chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("请重开原 Skill 创建验收目录") }
        let project = output.appendingPathComponent("public-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("# Public Skill creation fixture\n\nNative acceptance data, not a model response.\nRead the actual README and cite its lines.\n".utf8).write(to: project.appendingPathComponent("README.md"))
        let source = tasks.create(title: "Skill 创建入口验收", workspace: project.path)
        let global = tasks.create(title: "无工作区创建来源", workMode: .general)
        tasks.update(source) { $0.draft = "保留来源任务草稿 🧭" }
        tasks.update(global) { $0.draft = "Keep the original general draft 🧭" }
        let review = try AgentSkillCreation.create(store: tasks, sourceTaskID: source, workspace: project.path)
        let globalReview = try AgentSkillCreation.create(store: tasks, sourceTaskID: global, workspace: nil)
        try stageCreationFixture(review, name: "public-created-readme-check", tasks: tasks)
        try stageCreationFixture(globalReview, name: "public-global-readme-check", tasks: tasks)
        tasks.update(review) { $0.title = "原生 Skill 创建草稿（非模型）" }
        tasks.update(globalReview) { $0.title = "Native Skill draft (not model output)" }
        let ids = ["source": source, "global": global, "review": review, "globalReview": globalReview, "modelOutputsCreated": "false"]
        try JSONEncoder().encode(ids).write(to: file)
        control.showAgentTask(source); control.show(tab: "chat"); return ids
    }
    func runSkillCreationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少 Skill 创建环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("Skill 创建原生检查禁止模型请求") }
            defer { runtime.stopAll() }
            func refused(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
            func descendants(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) } }
            func taskNames() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: tasks.directory.path).filter { $0.hasSuffix(".json") }) }
            checks["nativeEntryHasIsolatedHomeWorkbenchAndNoSystemDelivery"] = usesAgent && tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            let negative = output.appendingPathComponent("live-authorization-negative"); try FileManager.default.createDirectory(at: negative, withIntermediateDirectories: false)
            var preferences = PetPreferences(); preferences.model = "deepseek-flash"; preferences.contextTokens = 8192; preferences.replyTokens = 512
            let authorization = negative.appendingPathComponent("skill-creation-authorization.json"), ledger = negative.appendingPathComponent("skill-creation-request-ledger.json")
            try Data("{}".utf8).write(to: negative.appendingPathComponent("input-hashes.json"))
            checks["missingLiveAuthorizationCreatesNoLedger"] = refused { _ = try AgentSkillCreationLiveBudget(output: negative, preferences: preferences) } && !FileManager.default.fileExists(atPath: ledger.path)
            let invalid = Data("{\"scope\":\"native-negative-only\",\"maximumRequests\":0}".utf8); try invalid.write(to: authorization)
            checks["wrongLiveScopeCreatesNoLedger"] = refused { _ = try AgentSkillCreationLiveBudget(output: negative, preferences: preferences) } && !FileManager.default.fileExists(atPath: ledger.path)
            let retained = negative.appendingPathComponent("retained-invalid-authorization.json"); try FileManager.default.moveItem(at: authorization, to: retained); try FileManager.default.createSymbolicLink(at: authorization, withDestinationURL: retained)
            checks["linkedLiveAuthorizationIsRejectedAndRetained"] = try refused { _ = try AgentSkillCreationLiveBudget(output: negative, preferences: preferences) } && Data(contentsOf: retained) == invalid && !FileManager.default.fileExists(atPath: ledger.path)
            checks["liveAllowanceHasItsOwnTwentyRequestLimit"] = AgentSkillCreationLiveBudget.maximum == 20 && attempts == 0
            let source = tasks.create(title: "独立创建来源", workMode: .general)
            tasks.update(source) { $0.draft = "保持来源草稿，不能复制为新会话 🧭" }
            let sourceFile = tasks.directory.appendingPathComponent(source + ".json"), sourceBytes = try Data(contentsOf: sourceFile)
            let catalog = try tasks.extensions.catalog(workspace: nil).map(\.id)
            let manager = AgentExtensionWindow(store: tasks, taskID: source); manager.prepareSettings(kind: .skill)
            var opened: String?
            checks["taskMenuRequiresWorkbenchCallback"] = manager.creationMenu()?.items.first?.isEnabled == false
            manager.onStartTask = { opened = $0 }
            guard let menu = manager.creationMenu() else { throw PetError("缺少 Skill 创建菜单") }
            checks["taskAndManualMenuKeepNativeActions"] = menu.items.map(\.title) == ["通过小鲸创建", "手动创建"] && menu.items.allSatisfy { $0.target === manager && $0.action != nil && $0.isEnabled }
            menu.performActionForItem(at: 0)
            guard let id = opened, let created = tasks.task(id), let creation = created.skillEvolutionJob?.creation else { throw PetError("菜单未创建独立任务") }
            checks["menuCreatesIndependentPlanWithoutMessagesRequestsOrInstalledSkill"] = try created.parentID == nil && created.mode == .plan && created.permission == .review && created.organizationMode == .general && created.workspace == nil && created.messages.isEmpty && created.skillDraft == nil && created.skillEvolutionJob?.approvedPlan == nil && attempts == 0 && (try tasks.extensions.catalog(workspace: nil).map(\.id)) == catalog
            checks["newTaskHasItsOwnOriginWithoutInventedSuggestionOrSource"] = creation.taskID == id && created.skillEvolutionJob?.sourceTaskID == nil && created.skillEvolutionJob?.sourceMessageID == nil && created.skillEvolutionJob?.suggestionID == nil && created.skillEvolutionJob?.sourceHash == nil
            checks["originalSourceBytesAndDraftStayExact"] = try Data(contentsOf: sourceFile) == sourceBytes && tasks.task(source)?.draft == "保持来源草稿，不能复制为新会话 🧭"
            let createdData = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            checks["newTaskDoesNotCopySourceDraftOrConversation"] = !String(decoding: createdData, as: UTF8.self).contains("保持来源草稿") && created.modelReceipts == nil && created.agent == nil && created.team == nil && created.automation == nil
            let command = AgentExtensionWindow(store: tasks, taskID: source); command.prepareSettings(kind: .command)
            checks["commandsKeepDirectManualCreation"] = command.creationMenu() == nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let legacy = Data("{\"sourceTaskID\":\"11111111-1111-4111-8111-111111111111\",\"sourceMessageID\":\"reply\",\"sourceTitle\":\"Original\",\"sourceHash\":\"source-hash\",\"suggestionID\":\"22222222-2222-4222-8222-222222222222\",\"title\":\"Original suggestion\",\"goal\":\"Original goal\",\"brief\":\"Original brief\"}".utf8)
            let legacyValue = try JSONDecoder().decode(AgentSkillEvolutionJob.self, from: legacy)
            let canonicalLegacy = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: legacy), options: [.sortedKeys, .withoutEscapingSlashes])
            checks["legacyJobSchemaRoundTripsWithoutCreationField"] = try encoder.encode(legacyValue) == canonicalLegacy && legacyValue.creation == nil
            var corrupt = created; corrupt.id = UUID().uuidString
            checks["copiedCreationJobCannotChangeTaskOwner"] = refused { _ = try AgentSkillDrafts.job(corrupt, store: tasks) }
            corrupt = created; corrupt.workMode = .coding
            checks["creationJobCannotChangeWorkMode"] = refused { _ = try AgentSkillDrafts.job(corrupt, store: tasks) }
            corrupt = created; corrupt.skillEvolutionJob?.suggestionID = UUID().uuidString
            checks["creationOriginCannotMixSuggestionMetadata"] = refused { _ = try AgentSkillDrafts.job(corrupt, store: tasks) }
            corrupt = created; corrupt.skillEvolutionJob?.creation = nil
            checks["missingOriginDoesNotBecomeAnUnvalidatedLegacyJob"] = refused { _ = try AgentSkillDrafts.job(corrupt, store: tasks) }
            let second = try AgentSkillCreation.create(store: tasks, sourceTaskID: source, workspace: nil)
            checks["draftBaseRejectsAnotherStandaloneTask"] = refused { _ = try AgentSkillDrafts.base(created.skillEvolutionJob!, store: tasks, task: tasks.task(second)!) }
            let index = tasks.directory.appendingPathComponent("index.json"), indexBytes = try Data(contentsOf: index), names = try taskNames(), count = tasks.tasks.count, selected = tasks.selectedID
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: index.path)
            checks["readOnlyIndexLeavesNoTaskOrSelectionOrOrphan"] = try refused { _ = try AgentSkillCreation.create(store: tasks, sourceTaskID: source, workspace: nil) } && tasks.tasks.count == count && tasks.selectedID == selected && (try Data(contentsOf: index)) == indexBytes && (try taskNames()) == names
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            var external = sourceBytes; external.append(Data("\n".utf8)); try external.write(to: sourceFile)
            checks["staleSettingsSourceCannotCreateTask"] = refused { _ = try AgentSkillCreation.create(store: tasks, sourceTaskID: source, workspace: nil) } && tasks.tasks.count == count
            try sourceBytes.write(to: sourceFile)
            let tools = AgentTools(store: tasks, taskID: id)
            for name in ["draft_skill", "write_file", "run_command", "delegate_task"] {
                let call = try creationCall(name, ["path": "should-not-exist.txt", "content": "refused", "command": "true"])
                var ran = false; do { _ = try await tools.execute(call); ran = true } catch {}
                checks["planRefuses-" + name] = !ran && refused { _ = try tools.approvalReason(for: call) }
            }
            checks["userRequirementEntersOrdinarySubmitWithoutStartingModel"] = runtime.submit("Create a reusable README verification Skill.", taskID: id, startImmediately: false) && tasks.task(id)?.messages.last?.content == "Create a reusable README verification Skill." && attempts == 0
            try stageCreationFixture(id, name: "native-created-readme-check", tasks: tasks)
            guard let staged = tasks.task(id), let draft = staged.skillDraft else { throw PetError("缺少原生创建草稿") }
            checks["approvedPlanStagesMultipleFilesWithoutInstalling"] = try staged.mode == .agent && staged.skillEvolutionJob?.approvedPlan != nil && Set(draft.files.keys) == ["SKILL.md", "templates/result.txt"] && draft.savedAt == nil && (try tasks.extensions.catalog(workspace: nil).map(\.id)) == catalog
            let review = try AgentSkillDraftReviewPage(store: tasks, taskID: id)
            let scope = descendants(review.pageContentView).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "skill-review-scope" }
            let name = descendants(review.pageContentView).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "skill-review-name" }
            checks["reviewDefaultsToUserAndKeepsNoWorkspaceProjectDisabled"] = scope?.indexOfSelectedItem == 0 && scope?.item(at: 1)?.isEnabled == false && scope?.menu?.autoenablesItems == false
            checks["reviewUsesSharedNativeNameInput"] = name is AgentDialogTextField && name?.stringValue == "native-created-readme-check" && name?.isEditable == true
            let revision = AgentSkillDrafts.revision(draft)
            checks["staleReviewCannotSaveSkill"] = refused { _ = try AgentSkillDrafts.apply(taskID: id, draftID: draft.id, revision: "stale", name: "native-created-readme-check", project: false, store: tasks) }
            let savedID = try AgentSkillDrafts.apply(taskID: id, draftID: draft.id, revision: revision, name: "native-created-readme-check", project: false, store: tasks)
            let saved = try tasks.extensions.item(savedID, workspace: nil), resources = try AgentExtensions.resourceData(AgentFiles(workspace: saved.root.path))
            checks["explicitApplySavesExactSkillAndResourceFiles"] = resources == draft.files.mapValues { Data($0.utf8) } && tasks.task(id)?.skillDraft?.savedID == savedID && tasks.task(id)?.skillDraft?.savedAt != nil
            checks["savingDoesNotTurnCreationIntoFakeSuggestion"] = tasks.task(id)?.skillEvolutionJob?.creation?.taskID == id && tasks.task(id)?.skillEvolutionJob?.sourceTaskID == nil
            try stageCreationFixture(second, name: "native-created-readme-check", tasks: tasks)
            let duplicate = tasks.task(second)!.skillDraft!
            checks["duplicateNameDoesNotOverwriteInstalledSkill"] = try refused { _ = try AgentSkillDrafts.apply(taskID: second, draftID: duplicate.id, revision: AgentSkillDrafts.revision(duplicate), name: "native-created-readme-check", project: false, store: tasks) } && (try AgentExtensions.resourceData(AgentFiles(workspace: saved.root.path))) == resources
            let group = output.appendingPathComponent("multi-source"), alpha = group.appendingPathComponent("Alpha"), beta = group.appendingPathComponent("Beta"), outside = output.appendingPathComponent("Outside")
            for path in [alpha, beta, outside] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); try Data("Public README\n".utf8).write(to: path.appendingPathComponent("README.md")) }
            let context = AgentWorkspaceScope(group: group.path, folders: [alpha.path, beta.path], primary: alpha.path)
            let multi = tasks.create(title: "双来源原任务", workspace: alpha.path, workspaceScope: context), multiFile = tasks.directory.appendingPathComponent(multi + ".json"), multiBytes = try Data(contentsOf: multiFile)
            let projectID = try AgentSkillCreation.create(store: tasks, sourceTaskID: multi, workspace: beta.path), projectTask = tasks.task(projectID)!
            checks["selectedSettingsSourceBecomesPrimaryWithoutLosingOtherRoots"] = projectTask.workspace == beta.path && projectTask.workspaceScope?.folders == context.folders && projectTask.workspaceScope?.group == context.group && projectTask.skillEvolutionJob?.creation?.workspaceScope == projectTask.workspaceScope
            checks["outsideSettingsSourceIsRejected"] = refused { _ = try AgentSkillCreation.create(store: tasks, sourceTaskID: multi, workspace: outside.path) }
            corrupt = projectTask; corrupt.workspaceScope?.folders = [beta.path]
            checks["creationScopeCannotLoseAnOriginalRoot"] = refused { _ = try AgentSkillDrafts.job(corrupt, store: tasks) }
            try stageCreationFixture(projectID, name: "native-project-readme-check", tasks: tasks)
            let projectReview = try AgentSkillDraftReviewPage(store: tasks, taskID: projectID)
            let projectMenu = descendants(projectReview.pageContentView).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "skill-review-scope" }
            checks["multiSourceReviewListsBothRootsAndStillDefaultsToUser"] = projectMenu?.numberOfItems == 3 && projectMenu?.indexOfSelectedItem == 0 && Set(projectMenu?.itemArray.compactMap { $0.representedObject as? String } ?? []) == Set(context.folders)
            let projectDraft = tasks.task(projectID)!.skillDraft!, projectRevision = AgentSkillDrafts.revision(projectDraft)
            checks["reviewCannotRedirectProjectSkillOutsideOriginalRoots"] = refused { _ = try AgentSkillDrafts.apply(taskID: projectID, draftID: projectDraft.id, revision: projectRevision, name: "native-project-readme-check", project: true, store: tasks, workspace: outside.path) }
            let projectSavedID = try AgentSkillDrafts.apply(taskID: projectID, draftID: projectDraft.id, revision: projectRevision, name: "native-project-readme-check", project: true, store: tasks, workspace: beta.path)
            let projectSaved = try tasks.extensions.item(projectSavedID, task: tasks.task(projectID)!)
            checks["explicitProjectSaveWritesSelectedRootOnly"] = projectSaved.file.path.hasPrefix(beta.path + "/.bluefatfish/skills/") && !FileManager.default.fileExists(atPath: alpha.appendingPathComponent(".bluefatfish/skills/native-project-readme-check").path) && !FileManager.default.fileExists(atPath: outside.appendingPathComponent(".bluefatfish").path)
            checks["bothOriginalTaskFilesStayByteIdentical"] = try Data(contentsOf: sourceFile) == sourceBytes && Data(contentsOf: multiFile) == multiBytes
            let loaded = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["coldReloadKeepsCreationIdentityAndSavedBundle"] = try loaded.task(id)?.skillEvolutionJob?.creation == creation && loaded.task(id)?.skillDraft?.savedID == savedID && AgentSkillDrafts.job(loaded.task(id)!, store: loaded).creation == creation && AgentExtensions.resourceData(AgentFiles(workspace: saved.root.path)) == resources
            let fork = tasks.fork(id)
            checks["normalBranchRemainsIndependentAndDoesNotInheritCreationJob"] = fork.flatMap(tasks.task).map { $0.parentID == id && $0.skillEvolutionJob == nil && $0.skillDraft == nil && $0.kind == nil } == true
            var next = tasks.task(id)!; let followup = AgentMessage(role: "user", content: "原生后续要求：补充复核步骤。")
            try AgentSkillDrafts.prepareNewRound(&next, message: followup)
            checks["savedCreationCanPlanAnotherRevisionWithoutOverwritingInstalledSkill"] = try next.mode == .plan && next.skillDraft == nil && next.skillDraftHistory?.last?.savedID == savedID && next.skillEvolutionJob?.approvedPlan == nil && next.skillEvolutionJob?.creation == creation && (try AgentExtensions.resourceData(AgentFiles(workspace: saved.root.path))) == resources
            checks["allNativeChecksRemainWithoutModelReceipts"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["success"] = checks.count >= 30 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = attempts; report["nativePlansAndDraftsAreNotModelOutputs"] = true; report["appPID"] = ProcessInfo.processInfo.processIdentifier
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("skill-creation-report.json"))
    }
}
