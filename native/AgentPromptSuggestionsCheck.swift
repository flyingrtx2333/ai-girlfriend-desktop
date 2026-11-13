import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func preparePromptSuggestionsUI(_ output: URL, seed: Bool) throws -> [String: String] {
        ensureAgent(); guard let tasks = agentStore, let service = agentRuntime?.promptSuggestions else { throw PetError("缺少提示建议验收环境") }
        let file = output.appendingPathComponent("prompt-suggestions-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["coding"], tasks.task(id) != nil else { throw PetError("提示建议原样例不可用") }; control.showAgentTask(id); control.show(tab: "chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        let project = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("# Public prompt suggestion fixture\n\nThis is native UI data, not a model response.\n".utf8).write(to: project.appendingPathComponent("README.md"))
        let coding = tasks.create(title: "提示建议公开样例", workspace: project.path, mode: .agent)
        let general = tasks.create(title: "无工作区英文建议样例", mode: .ask, workMode: .general)
        let waiting = tasks.create(title: "待回答不显示建议", mode: .ask)
        for id in [coding, general, waiting] {
            let english = id == general
            tasks.update(id) {
                $0.messages = [AgentMessage(role: "user", content: english ? "Public native fixture: explain how to inspect disk space." : "公开原生样例：查看磁盘空间的方法。"), AgentMessage(role: "assistant", content: english ? "Native fixture, not a model response: df -h shows available disk space." : "原生界面样例，不是模型输出：可以使用 df -h 查看磁盘空间。")]
                $0.status = .completed; $0.draft = english ? "Keep my unsent draft 🧭" : "保留原有未发送草稿 🧭"
            }
            let record = tasks.task(id)!, source = AgentPromptSuggestions.source(record)!
            try service.save(english ? ["How do I inspect a specific volume?", "Explain the available-space column.", "Compare disk space and memory usage."] : ["如何查看某个磁盘的剩余空间？", "解释容量、已用与可用三列的区别。", "如何分别查看磁盘空间和内存占用？"], id: id, source: source, model: "native-fixture")
        }
        let call = AgentToolCall(id: UUID().uuidString, name: "ask_user", arguments: "{\"question\":\"公开待回答样例\"}")
        tasks.update(waiting) { $0.status = .waiting; $0.pendingCalls = [call]; $0.approvals = [AgentApproval(call: call, reason: "公开待回答样例", workspace: nil)] }
        let ids = ["coding": coding, "general": general, "waiting": waiting, "modelOutputsCreated": "false"]
        try JSONEncoder().encode(ids).write(to: file); control.showAgentTask(coding); control.show(tab: "chat"); return ids
    }
    func runPromptSuggestionsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少提示建议验收环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("提示建议本地检查禁止模型请求") }
            defer { runtime.stopAll() }
            let ids = try preparePromptSuggestionsUI(output, seed: true), id = ids["coding"]!, other = ids["general"]!, waiting = ids["waiting"]!, service = runtime.promptSuggestions
            checks["independentHomeAndSystemDeliveryBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            checks["defaultEnabledWithoutCreatingConfiguration"] = generalSettings.settings.promptSuggestions && !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("general.json").path)
            checks["validBilingualSuggestionsAndEmptyResultDecode"] = try AgentPromptSuggestions.parse("{\"suggestions\":[\"进一步解释？\",\"Explain the result.\"]}").count == 2 && AgentPromptSuggestions.parse("{\"suggestions\":[]}").isEmpty
            for (name, raw) in ["extra-key": "{\"suggestions\":[],\"other\":1}", "type": "{\"suggestions\":[1]}", "count": "{\"suggestions\":[\"a\",\"b\",\"c\",\"d\"]}", "duplicate": "{\"suggestions\":[\" Test \",\"test\"]}", "empty": "{\"suggestions\":[\" \"]}", "newline": "{\"suggestions\":[\"a\\nb\"]}", "command": "{\"suggestions\":[\"/automation\"]}", "markdown": "```json\n{\"suggestions\":[]}\n```"] {
                var refused = false; do { _ = try AgentPromptSuggestions.parse(raw) } catch { refused = true }; checks["invalid-" + name + "-rejected"] = refused
            }
            let max = String(repeating: "🐳", count: 40), tooLong = max + "a"
            func json(_ text: String) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: ["suggestions": [text]]), as: UTF8.self) }
            checks["UTF16BoundaryAcceptsFortyEmoji"] = try AgentPromptSuggestions.parse(json(max)) == [max]
            var refused = false; do { _ = try AgentPromptSuggestions.parse(json(tooLong)) } catch { refused = true }; checks["UTF16OverflowRejected"] = refused
            let original = tasks.task(id)!, saved = try JSONEncoder().encode(original), source = AgentPromptSuggestions.source(original)!, file = tasks.directory.appendingPathComponent(id + ".json")
            checks["newMetadataReopensWithoutEnteringModelWire"] = try JSONDecoder().decode(AgentTaskRecord.self, from: saved).messages.last?.promptSuggestions?.items.count == 3 && original.messages.last?.wire["promptSuggestions"] == nil && original.messages.last?.wire["content"] as? String == original.messages.last?.content
            var legacy = original; legacy.messages[legacy.messages.count - 1].promptSuggestions = nil
            checks["oldMessagesDecodeWithoutSuggestions"] = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONEncoder().encode(legacy)).messages.last?.promptSuggestions == nil
            checks["nativeFixtureCannotTriggerAutomaticModelRequest"] = !service.generate(id, preferences: store.preferences, key: "") && !service.generate(waiting, preferences: store.preferences, key: "") && attempts == 0
            var p = store.preferences; p.contextTokens = 8192; p.replyTokens = 512
            var large = original; large.messages[0].content = String(repeating: "问题 PUBLIC_TEST_SECRET ", count: 5000); large.messages[1].content = String(repeating: "事实结果 ", count: 10000)
            let input = try AgentPromptSuggestions.input(large, preferences: p, secret: "PUBLIC_TEST_SECRET")
            let body = try AgentModel.requestBody(preferences: p, system: AgentPromptSuggestions.system, messages: [AgentMessage(role: "user", content: input)], tools: [])
            checks["auxiliaryInputFitsExisting8192_512AndHasNoTools"] = body["tools"] == nil && body["tool_choice"] == nil && !input.contains("PUBLIC_TEST_SECRET") && input.contains("[隐藏]") && (try? JSONSerialization.jsonObject(with: Data(input.utf8))) != nil
            large.messages[0].content = "a" + String(repeating: "\u{301}", count: 20000)
            checks["oversizedSingleGraphemeTerminatesWithinBudget"] = try AgentPromptSuggestions.input(large, preferences: p, secret: "").utf8.count < 20000
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            control.showAgentTask(id); control.show(tab: "chat"); control.window?.makeKeyAndOrderFront(nil); control.renderMessages(); await wait(0.1)
            let draft = original.draft!, suggestion = service.items(original)[0]
            checks["completedReplyShowsThreeNativeSuggestionButtons"] = control.promptSuggestionsReadback()["rowVisible"] as? Bool == true && descendants(control.window!.contentView!).filter { $0.identifier?.rawValue.hasPrefix("prompt-suggestion-") == true }.count == 3
            service.fail(id, PetError("公开失败样例")); control.renderMessages()
            checks["optionalFailureKeepsCompletedAnswerAndShowsRetry"] = service.error(tasks.task(id)!) == "公开失败样例" && tasks.task(id)?.status == .completed && descendants(control.window!.contentView!).contains { ($0 as? NSButton)?.accessibilityLabel() == "重新生成提示建议" }
            service.cancel(id); control.renderMessages(); checks["cancellingSupplementaryWorkClearsErrorImmediately"] = service.error(tasks.task(id)!) == nil && control.promptSuggestionsReadback()["error"] as? String == ""
            checks["clickAppendsDraftWithoutSendingOrChangingHistory"] = try control.usePromptSuggestion(suggestion, taskID: id, source: source) && tasks.task(id)?.draft == draft + "\n" + suggestion && tasks.task(id)?.messages.count == original.messages.count && tasks.task(id)?.status == .completed && (tasks.task(id)?.modelReceipts ?? []).isEmpty && attempts == 0
            checks["ChineseSuggestionPlacesCaretAfterInsertedText"] = control.promptSuggestionsReadback()["caretAtEnd"] as? Bool == true
            control.showAgentTask(other); control.show(tab: "chat"); control.renderMessages()
            let english = tasks.task(other)!, englishSource = AgentPromptSuggestions.source(english)!
            checks["askWithoutWorkspaceSupportsEnglishSuggestions"] = english.workspace == nil && english.mode == .ask && service.items(english).count == 3 && control.usePromptSuggestion(service.items(english)[0], taskID: other, source: englishSource)
            checks["EnglishSuggestionPlacesCaretAfterInsertedText"] = control.promptSuggestionsReadback()["caretAtEnd"] as? Bool == true
            checks["staleOtherTaskClickCannotChangeCurrentDraft"] = !control.usePromptSuggestion(suggestion, taskID: id, source: source) && tasks.task(other)?.draft?.hasPrefix("Keep my unsent draft 🧭\n") == true
            control.showAgentTask(waiting); control.show(tab: "chat"); control.renderMessages()
            checks["waitingApprovalHasNoSuggestionRow"] = service.items(tasks.task(waiting)!).isEmpty && control.promptSuggestionsReadback()["rowVisible"] as? Bool == false
            var settings = generalSettings.settings; settings.promptSuggestions = false; try generalSettings.save(settings)
            control.showAgentTask(id); control.show(tab: "chat"); control.renderMessages()
            checks["disableHidesWithoutErasingSavedSuggestions"] = service.items(tasks.task(id)!).isEmpty && tasks.task(id)?.messages.last?.promptSuggestions?.items.count == 3 && control.promptSuggestionsReadback()["rowVisible"] as? Bool == false && !control.usePromptSuggestion(suggestion, taskID: id, source: source)
            let generalFile = store.directory.appendingPathComponent("general.json"), offBytes = try Data(contentsOf: generalFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: generalFile.path)
            settings.promptSuggestions = true; refused = false; do { try generalSettings.save(settings) } catch { refused = true }
            checks["readOnlyPreferenceKeepsDisabledStateAndBytes"] = try refused && !generalSettings.settings.promptSuggestions && Data(contentsOf: generalFile) == offBytes
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: generalFile.path); try generalSettings.save(settings)
            checks["enabledPreferencePersistsExactly"] = AgentGeneralSettings(directory: store.directory).settings.promptSuggestions && runtime.taskSettings().promptSuggestions
            let oldDir = output.appendingPathComponent("legacy-general"); try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: false)
            var old = try JSONSerialization.jsonObject(with: Data(contentsOf: generalFile)) as! [String: Any]; old.removeValue(forKey: "promptSuggestions"); try JSONSerialization.data(withJSONObject: old).write(to: oldDir.appendingPathComponent("general.json"))
            checks["legacyPreferenceDefaultsOnWithoutRewriting"] = AgentGeneralSettings(directory: oldDir).settings.promptSuggestions && AgentGeneralSettings(directory: oldDir).error == nil
            old["promptSuggestions"] = "yes"; try JSONSerialization.data(withJSONObject: old).write(to: oldDir.appendingPathComponent("general.json")); checks["nonBooleanPreferenceRejected"] = AgentGeneralSettings(directory: oldDir).error != nil
            let before = try Data(contentsOf: file), record = tasks.task(id)!
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path); refused = false
            do { try service.save(["公开写入检查"], id: id, source: source, model: "native-fixture") } catch { refused = true }
            checks["readOnlyTaskKeepsAnswerStatusDraftAndBytes"] = try refused && Data(contentsOf: file) == before && tasks.task(id)?.status == .completed && tasks.task(id)?.draft == record.draft && tasks.task(id)?.messages.last?.promptSuggestions?.items == record.messages.last?.promptSuggestions?.items
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var external = before; external.append(Data("\n".utf8)); try external.write(to: file); refused = false
            do { try service.save(["公开冲突检查"], id: id, source: source, model: "native-fixture") } catch { refused = true }
            checks["externalTaskChangeCannotBeOverwritten"] = try refused && Data(contentsOf: file) == external
            try before.write(to: file)
            tasks.update(id) { $0.mode = .ask }; refused = false
            do { try service.save(["过期建议"], id: id, source: source, model: "native-fixture") } catch { refused = true }
            checks["scopeChangeRejectsLateResultsAndOldButtons"] = refused && service.items(tasks.task(id)!).isEmpty && !control.usePromptSuggestion(suggestion, taskID: id, source: source)
            tasks.update(id) { $0.mode = .agent; $0.messages.append(AgentMessage(role: "user", content: "新的追问公开样例")) }
            checks["newHumanRoundHidesPreviousSuggestionsKeepsMetadata"] = service.items(tasks.task(id)!).isEmpty && tasks.task(id)?.messages[1].promptSuggestions?.items.count == 3
            control.showAgentTask(other); _ = control.showSettingsCategory("general"); control.window?.contentView?.layoutSubtreeIfNeeded()
            guard let root = control.window?.contentView, let toggle = descendants(root).first(where: { $0.identifier?.rawValue == "general-prompt-suggestions" }) as? NSSwitch else { throw PetError("提示建议未接入常规内容页") }
            toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
            checks["nativeSettingsToggleSavesWithoutModal"] = !generalSettings.settings.promptSuggestions && control.window?.attachedSheet == nil
            let count = descendants(root).filter { $0.identifier?.rawValue.hasPrefix("general-") == true && $0 is NSControl }.count
            checks["generalIncludesTwelveControls"] = count == 12
            checks["noProviderRequestsOrForgedUsage"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("prompt-suggestions-report.json"), options: .atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
