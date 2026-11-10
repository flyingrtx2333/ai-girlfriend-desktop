import AppKit

@MainActor extension AppDelegate {
    func runAgentAutomationDraftCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        let fm = FileManager.default
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        defer { agentRuntime?.stopAll(); agentStore?.automations.stop() }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("自动化草稿检查不授权模型请求") }
            guard !fm.fileExists(atPath: output.appendingPathComponent("automation-draft-started.json").path) else { throw PetError("本轮原生检查已开始，不能重放") }
            try write(["appPID": getpid()], "automation-draft-started.json"); await wait(0.25)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("自动化草稿检查禁止模型传输") }
            let service = tasks.automations, workspace = output.appendingPathComponent("workspace"), source = workspace.appendingPathComponent("README.md"), sourceData = try Data(contentsOf: source)
            service.start(store: tasks, runtime: runtime); guard service.isStarted else { throw PetError(service.error ?? "自动化未启动") }
            let config = service.directory.appendingPathComponent("definitions.json")
            var original = AgentAutomation(name: "保留的本机计划", prompt: "只读核对公开 README，不修改文件。", workspace: workspace.path); original.workMode = .general
            try service.save(original, expected: nil); let originalBytes = try Data(contentsOf: config)
            let owner = tasks.create(title: "会话创建 README 自动化", workspace: workspace.path, mode: .ask, workMode: .general)
            tasks.update(owner) { $0.draft = "保留的自动化会话草稿，不发送。" }
            let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400 * 30))
            let arguments: [String: Any] = ["name": "每周 README 核对", "prompt": "读取当前项目的 README.md，列出标题及对应原文行号；缺少文件时说明，不修改文件。", "schedule": ["frequency": "weekly", "time_zone": "Asia/Shanghai", "hour": 9, "minute": 45, "weekdays": [2, 6], "expires_at": expires], "output": "merged"]
            @MainActor func invoke(_ callID: String, _ args: [String: Any], taskID: String) async throws -> AgentToolResult {
                let call = AgentToolCall(id: callID, name: "draft_automation", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)), tools = AgentTools(store: tasks, taskID: taskID)
                guard try tools.approvalReason(for: call) == nil else { throw PetError("草稿不应修改自动化目录") }; return try await tools.execute(call)
            }
            let result = try await invoke("actual-automation-draft", arguments, taskID: owner)
            let receipt = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any], draftID = receipt["draft_id"] as! String
            let draft = try AgentAutomationDrafts.load(draftID, taskID: owner, store: tasks)
            checks["productionToolCreatesOnlyTaskDraftAndKeepsDefinitionBytes"] = try Data(contentsOf: config) == originalBytes && tasks.task(owner)?.automationDrafts?.count == 1 && tasks.task(owner)?.draft == "保留的自动化会话草稿，不发送。" && receipt["saved"] as? Bool == false
            checks["proposalUsesPausedReadOnlyReviewDefaultsAndFrozenProject"] = !draft.automation.enabled && draft.automation.readOnly && !draft.automation.network && draft.automation.permission == .review && draft.automation.executor == "default" && draft.automation.model.isEmpty && draft.automation.workspace == workspace.path && draft.automation.workMode == .general && draft.automation.output == .merged
            checks["weeklyTimeZoneWeekdaysAndExpirationPersist"] = draft.automation.schedule.frequency == .weekly && draft.automation.schedule.timeZone == "Asia/Shanghai" && draft.automation.schedule.weekdays == [2, 6] && draft.automation.schedule.hour == 9 && draft.automation.schedule.minute == 45 && draft.automation.schedule.expiration != nil
            checks["sameCallIsIdempotent"] = try await invoke("actual-automation-draft", arguments, taskID: owner).text == result.text && tasks.task(owner)?.automationDrafts?.count == 1
            var rejected = false
            do { _ = try await invoke("actual-automation-draft", arguments.merging(["name": "其他计划"]) { _, n in n }, taskID: owner) } catch { rejected = true }
            checks["conflictingCallDoesNotOverwriteOriginal"] = rejected && tasks.task(owner)?.automationDrafts?.first?.automation.name == draft.automation.name
            var invalid = [arguments.merging(["enabled": true]) { _, n in n }, arguments.merging(["permission": "automatic"]) { _, n in n }, arguments.merging(["workspace": output.path]) { _, n in n }, arguments.merging(["model": "unreviewed"]) { _, n in n }, arguments.merging(["name": "bad\nname"]) { _, n in n }, arguments.merging(["prompt": ""]) { _, n in n }]
            for schedule: [String: Any] in [["frequency": "daily", "time_zone": "Asia/Shanghai", "hour": 24, "minute": 0], ["frequency": "weekly", "time_zone": "Asia/Shanghai", "hour": 9, "minute": 0, "weekdays": [2, 2]], ["frequency": "interval", "time_zone": "Asia/Shanghai", "interval_minutes": true], ["frequency": "daily", "time_zone": "invalid", "hour": 9, "minute": 0], ["frequency": "daily", "time_zone": "Asia/Shanghai", "hour": 9, "minute": 0, "enabled": true], ["frequency": "once", "time_zone": "Asia/Shanghai", "at": "2020-01-01T00:00:00Z"], ["frequency": "once", "time_zone": "Asia/Shanghai", "at": "2026-11-12 09:00"]] { invalid.append(arguments.merging(["schedule": schedule]) { _, n in n }) }
            for at in ["2027-02-30T09:00:00+08:00", "2027-01-01T09:00:00", "2027-01-01T25:00:00Z"] { invalid.append(arguments.merging(["schedule": ["frequency": "once", "time_zone": "Asia/Shanghai", "at": at]]) { _, n in n }) }
            var denied = 0
            for (i, args) in invalid.enumerated() { do { _ = try await invoke("invalid-\(i)", args, taskID: owner) } catch { denied += 1 } }
            checks["unreviewedPrivilegesInvalidSchedulesAndMixedFieldsRejected"] = try denied == invalid.count && Data(contentsOf: config) == originalBytes && tasks.task(owner)?.automationDrafts?.count == 1
            var tampered = draft; tampered.automation.enabled = true
            rejected = false; do { _ = try AgentAutomationDrafts.checked(tampered, taskID: owner, service: service) } catch { rejected = true }
            checks["storedProposalCannotSmuggleActivation"] = rejected
            let other = tasks.create(title: "无项目自动化草稿")
            rejected = false; do { _ = try AgentAutomationDrafts.load(draftID, taskID: other, store: tasks) } catch { rejected = true }
            checks["foreignTaskCannotConfigureProposal"] = rejected
            tasks.update(owner) { $0.archived = true }
            rejected = false; do { _ = try AgentAutomationDrafts.load(draftID, taskID: owner, store: tasks) } catch { rejected = true }
            checks["archivedSourceCannotConfigureProposal"] = rejected; tasks.update(owner) { $0.archived = false }
            let withoutProject = try await invoke("actual-no-workspace", arguments, taskID: other)
            let noProjectID = (try JSONSerialization.jsonObject(with: Data(withoutProject.text.utf8)) as! [String: Any])["draft_id"] as! String
            let noProject = try AgentAutomationDrafts.load(noProjectID, taskID: other, store: tasks)
            rejected = false; do { try service.save(noProject.automation, expected: nil) } catch { rejected = true }
            checks["noWorkspaceCanDraftButMustChooseProjectBeforeSave"] = rejected && noProject.automation.workspace.isEmpty && tasks.task(other)?.messages.isEmpty == true
            let reopened = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["actualTaskReloadKeepsProposalIdentityAndOriginalText"] = try AgentAutomationDrafts.load(draftID, taskID: owner, store: reopened).automation.id == draft.automation.id && reopened.task(owner)?.automationDrafts?.first?.automation.prompt == draft.automation.prompt
            let index = try JSONSerialization.jsonObject(with: Data(contentsOf: tasks.directory.appendingPathComponent("index.json"))) as! [String: Any]
            checks["draftBodyIsExcludedFromTaskIndex"] = (index["tasks"] as? [[String: Any]])?.allSatisfy { $0["automationDrafts"] == nil } == true
            rejected = false; do { try AgentAutomationDrafts.markSaved(draftID, taskID: owner, automationID: draft.automation.id, store: tasks) } catch { rejected = true }
            checks["unsavedProposalCannotClaimSaved"] = rejected && tasks.task(owner)?.automationDrafts?.first?.savedAt == nil
            try service.save(draft.automation, expected: nil); try AgentAutomationDrafts.markSaved(draftID, taskID: owner, automationID: draft.automation.id, store: tasks)
            let savedAt = tasks.task(owner)?.automationDrafts?.first?.savedAt
            try AgentAutomationDrafts.markSaved(draftID, taskID: owner, automationID: draft.automation.id, store: tasks)
            checks["actualPausedSaveMarksExactIDOnceWithoutCreatingRun"] = try savedAt != nil && tasks.task(owner)?.automationDrafts?.first?.savedAt == savedAt && service.values.first { $0.id == draft.automation.id }?.nextRun == nil && service.history().total == 0
            service.stop(); service.start(store: tasks, runtime: runtime)
            checks["schedulerRestartAcceptsSavedGeneralWorkModeAndKeepsOriginal"] = service.isStarted && service.values.count == 2 && service.values.allSatisfy { $0.workMode == .general && !$0.enabled } && service.values.contains { $0.id == original.id && $0.prompt == original.prompt }
            guard checks["schedulerRestartAcceptsSavedGeneralWorkModeAndKeepsOriginal"] == true else { throw PetError(service.error ?? "自动化重读失败") }
            let beforeWrite = service.values.first { $0.id == draft.automation.id }!, writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); writer.arguments = ["-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b'\\n')", config.path]; try writer.run(); writer.waitUntilExit()
            let external = try Data(contentsOf: config); var edit = beforeWrite; edit.prompt += "\n仅报告事实。"
            rejected = false; do { try service.save(edit, expected: beforeWrite) } catch { rejected = true }
            checks["independentWriterConflictPreservesAllExternalBytes"] = try rejected && writer.terminationStatus == 0 && Data(contentsOf: config) == external && service.values.first { $0.id == beforeWrite.id }?.prompt == beforeWrite.prompt
            report["independentWriterPID"] = writer.processIdentifier
            service.stop(); service.start(store: tasks, runtime: runtime); guard service.isStarted else { throw PetError(service.error ?? "重读外部配置失败") }
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
            rejected = false; do { try service.save(edit, expected: beforeWrite) } catch { rejected = true }
            checks["readOnlyConfigurationIsNotReplaced"] = try rejected && Data(contentsOf: config) == external; try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            for parentLink in [false, true] {
                let root = output.appendingPathComponent(parentLink ? "parent-link-profile" : "file-link-profile"), linked = AgentAutomations(profile: root)
                try fm.createDirectory(at: root, withIntermediateDirectories: true); linked.start(store: tasks, runtime: runtime); guard linked.isStarted else { throw PetError(linked.error ?? "链接前置目录未启动") }
                let target: URL
                if parentLink {
                    try linked.save(original, expected: nil); let retained = output.appendingPathComponent("retained-automations"); try fm.moveItem(at: linked.directory, to: retained); try fm.createSymbolicLink(at: linked.directory, withDestinationURL: retained); target = retained.appendingPathComponent("definitions.json")
                } else { target = output.appendingPathComponent("retained-definitions.json"); try external.write(to: target); try fm.createSymbolicLink(at: linked.directory.appendingPathComponent("definitions.json"), withDestinationURL: target) }
                let bytes = try Data(contentsOf: target); rejected = false
                do { try linked.save(draft.automation, expected: nil) } catch { rejected = true }
                checks[parentLink ? "parentLinkCannotRedirectConfigurationSave" : "fileLinkCannotRedirectConfigurationSave"] = try rejected && Data(contentsOf: target) == bytes; linked.stop()
            }
            var enabled = service.values.first { $0.id == draft.automation.id }!; enabled.enabled = true; enabled.schedule.frequency = .once; enabled.schedule.date = Date().addingTimeInterval(86_400); enabled.schedule.expiration = nil
            try service.save(enabled, expected: beforeWrite)
            checks["explicitReviewedEnableSchedulesOnlyFutureTime"] = service.values.first { $0.id == enabled.id }?.nextRun == enabled.schedule.date && service.values.first { $0.id == enabled.id }?.enabled == true
            try service.setPaused(enabled.id, paused: true); await wait(0.3)
            checks["pausedDefinitionCreatesNoRunOrTask"] = try service.history().total == 0 && service.values.first { $0.id == enabled.id }?.nextRun == nil && attempts == 0
            let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(172_800))
            for schedule: [String: Any] in [["frequency": "once", "time_zone": "Asia/Shanghai", "at": future], ["frequency": "daily", "time_zone": "America/New_York", "hour": 8, "minute": 15], ["frequency": "interval", "time_zone": "UTC", "interval_minutes": 37, "at": future, "expires_at": expires]] {
                _ = try await invoke("frequency-" + (schedule["frequency"] as! String), arguments.merging(["schedule": schedule]) { _, n in n }, taskID: owner)
            }
            let frequencies = Set((tasks.task(owner)?.automationDrafts ?? []).map { $0.automation.schedule.frequency })
            checks["allFourSchedulesUseProductionParserAndPersist"] = frequencies == Set(AgentAutomationFrequency.allCases)
            let intervalDraft = tasks.task(owner)!.automationDrafts!.first { $0.callID == "frequency-interval" }!
            let intervalArgs = arguments.merging(["schedule": ["frequency": "interval", "time_zone": "UTC", "interval_minutes": 37, "at": future, "expires_at": expires]]) { _, n in n }
            _ = try await invoke("frequency-interval", intervalArgs, taskID: owner)
            checks["intervalReplayKeepsOriginalAnchorAndID"] = tasks.task(owner)?.automationDrafts?.first { $0.callID == "frequency-interval" }?.automation.schedule.date == intervalDraft.automation.schedule.date && tasks.task(owner)?.automationDrafts?.filter { $0.callID == "frequency-interval" }.count == 1
            var reviewedInterval = intervalDraft.automation; reviewedInterval.name = "已审阅的固定间隔"; reviewedInterval.enabled = true
            try service.save(reviewedInterval, expected: nil)
            checks["savingIntervalKeepsExplicitFutureAnchorAndNextRun"] = service.values.first { $0.id == reviewedInterval.id }?.schedule.date == reviewedInterval.schedule.date && service.values.first { $0.id == reviewedInterval.id }?.nextRun == reviewedInterval.schedule.date
            try service.setPaused(reviewedInterval.id, paused: true)
            for i in (tasks.task(owner)?.automationDrafts?.count ?? 0)..<8 { _ = try await invoke("bounded-\(i)", arguments, taskID: owner) }
            rejected = false; do { _ = try await invoke("ninth", arguments, taskID: owner) } catch { rejected = true }
            checks["eightProposalLimitKeepsExistingDrafts"] = rejected && tasks.task(owner)?.automationDrafts?.count == 8
            let commandTask = tasks.create(title: "自动化命令原文", workspace: workspace.path, mode: .ask)
            let command = try runtime.prepareInput("/automation 每周核对 README", attachmentIDs: [], task: tasks.task(commandTask)!)
            tasks.update(commandTask) { $0.activateExtensions(command) }
            checks["slashInputKeepsOriginalAndActivatesOnlyAutomationTools"] = command.content == "/automation 每周核对 README" && command.extensionInstructions?.contains("draft_automation") == true && tasks.task(commandTask)?.toolGroups == ["automations"] && tasks.task(commandTask)?.messages.isEmpty == true
            let conversation = try AgentAutomationDrafts.createConversation(store: tasks, sourceID: owner)
            checks["assistantEntryCreatesUnsentScopedConversationAndKeepsSourceDraft"] = tasks.task(conversation)?.workspace == workspace.path && tasks.task(conversation)?.workMode == .general && tasks.task(conversation)?.draft == "/automation " && tasks.task(conversation)?.messages.isEmpty == true && tasks.task(owner)?.draft == "保留的自动化会话草稿，不发送。"
            checks["allModesExposeDraftOnlyWhenRequested"] = AgentMode.allCases.allSatisfy { mode in
                let loaded = AgentTools.definitions(mode: mode, groups: ["automations"]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                let unloaded = AgentTools.definitions(mode: mode, groups: []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                return loaded.contains("draft_automation") && !unloaded.contains("draft_automation")
            }
            checks["originalDefinitionAndPublicSourceRemain"] = try service.values.contains { $0.id == original.id && $0.name == original.name && $0.prompt == original.prompt && !$0.enabled && $0.workMode == .general } && Data(contentsOf: source) == sourceData
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("自动化草稿原生检查未全部通过") }
            let ui = tasks.create(title: "创建 README 定时核对", workspace: workspace.path, mode: .ask, workMode: .general)
            tasks.update(ui) { $0.draft = "保留的窗口草稿，不发送。" }
            let uiResult = try await invoke("actual-window-automation-draft", arguments.merging(["name": "README 定时核对"]) { _, n in n }, taskID: ui)
            let uiReceipt = try JSONSerialization.jsonObject(with: Data(uiResult.text.utf8)) as! [String: Any]
            report["appPID"] = getpid(); report["binaryHash"] = AgentFiles.hash(try Data(contentsOf: Bundle.main.executableURL!)); report["taskID"] = ui; report["draftID"] = uiReceipt["draft_id"]; report["draftReceipt"] = uiReceipt; report["sourceHash"] = AgentFiles.hash(sourceData); report["originalAutomationID"] = original.id
            let preview = Date(), uiDraft = try AgentAutomationDrafts.load(uiReceipt["draft_id"] as! String, taskID: ui, store: tasks)
            report["previewReference"] = preview.timeIntervalSince1970; report["previewNext"] = uiDraft.automation.schedule.next(after: preview)?.timeIntervalSince1970
            if CommandLine.arguments.contains("--hold-automation-draft-ui") {
                control.showAgentTask(ui); control.show(tab: "chat"); try write(report.merging(["checks": checks, "modelRequests": attempts]) { _, n in n }, "automation-draft-ui-ready.json")
                let deadline = Date().addingTimeInterval(7200)
                while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-automation-draft-ui").path) { await wait(0.25) }
            }
            checks["noModelAttemptAssistantReplyReceiptOrActiveJob"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains { $0.role == "assistant" } && !runtime.isRunning($0.id) }
            report["blockedModelAttempts"] = attempts; report["activeJobs"] = tasks.tasks.contains { runtime.isRunning($0.id) }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? write(report, "automation-draft-result.json")
    }
}
