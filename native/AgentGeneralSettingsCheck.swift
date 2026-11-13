import AppKit
import UserNotifications

@MainActor extension AppDelegate {
    func runGeneralSettingsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少常规设置验收环境") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("常规设置验收禁止模型请求") }
            checks["IndependentHomeAndSystemDeliveryBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            let service = generalSettings, file = store.directory.appendingPathComponent("general.json")
            let a = tasks.create(title: "常规设置原任务", mode: .ask), b = tasks.create(title: "另一项原任务", mode: .ask)
            tasks.update(a) { $0.draft = "原有中文草稿 🧭" }; tasks.update(b) { $0.draft = "另一个窗口的原草稿" }
            control.showAgentTask(a); control.show(tab: "chat")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originals = try [a: encoder.encode(tasks.task(a)!), b: encoder.encode(tasks.task(b)!)]
            checks["DefaultsDoNotCreateConfiguration"] = service.settings == .init() && !FileManager.default.fileExists(atPath: file.path)
            var value = service.settings; value.completionNotifications = .always; try service.save(value)
            let first = try Data(contentsOf: file)
            checks["PrivateConfigurationReloadsExactly"] = try AgentGeneralSettings(directory: store.directory).settings == value && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            try service.save(value); checks["IdenticalSaveLeavesBytesExact"] = try Data(contentsOf: file) == first
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            var next = value; next.menuBarIcon = false; var refused = false
            do { try service.save(next) } catch { refused = true }
            checks["ReadOnlyRefusesWithoutChangingRuntimeOrBytes"] = try refused && service.settings == value && Data(contentsOf: file) == first && statusItem?.isVisible == true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let other = AgentGeneralSettings(directory: store.directory); var external = other.settings; external.questionNotifications = false; try other.save(external)
            let externalBytes = try Data(contentsOf: file); refused = false
            do { try service.save(next) } catch { refused = true }
            checks["ExternalConflictKeepsBothRuntimeAndExternalBytes"] = try refused && service.settings == value && Data(contentsOf: file) == externalBytes
            service.reload(); service.apply(); checks["ExplicitReloadAcceptsExternalPreference"] = service.settings == external
            try service.save(.init())
            let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let legacyDirectory = output.appendingPathComponent("legacy-general"); try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: false)
            var legacy = baseline; legacy.removeValue(forKey: "runningInput"); legacy.removeValue(forKey: "goalMaximumTurns"); legacy.removeValue(forKey: "slashMenuPresentation"); legacy.removeValue(forKey: "artifactLocation")
            let legacyBytes = try JSONSerialization.data(withJSONObject: legacy), legacyFile = legacyDirectory.appendingPathComponent("general.json"); try legacyBytes.write(to: legacyFile)
            let old = AgentGeneralSettings(directory: legacyDirectory); try old.save(old.settings)
            checks["LegacyFiveKeyConfigurationLoadsWithoutRewriting"] = try old.error == nil && old.settings.runningInput == .queue && old.settings.goalMaximumTurns == 20 && old.settings.slashMenuPresentation == .recent && old.settings.artifactLocation == .workspace && Data(contentsOf: legacyFile) == legacyBytes
            var upgraded = old.settings; upgraded.runningInput = .interrupt; try old.save(upgraded)
            checks["ExplicitLegacyEditKeepsExistingNotificationPreferences"] = AgentGeneralSettings(directory: legacyDirectory).settings == upgraded && upgraded.completionNotifications == .unfocused && upgraded.approvalNotifications && upgraded.questionNotifications && upgraded.menuBarIcon
            let previousDirectory = output.appendingPathComponent("previous-general"); try FileManager.default.createDirectory(at: previousDirectory, withIntermediateDirectories: false)
            var previous = baseline; previous.removeValue(forKey: "slashMenuPresentation"); previous.removeValue(forKey: "artifactLocation"); previous["runningInput"] = "interrupt"; previous["goalMaximumTurns"] = 100
            let previousBytes = try JSONSerialization.data(withJSONObject: previous), previousFile = previousDirectory.appendingPathComponent("general.json"); try previousBytes.write(to: previousFile)
            let existing = AgentGeneralSettings(directory: previousDirectory); try existing.save(existing.settings)
            checks["ExistingTaskPreferencesLoadWithoutRewritingOrResetting"] = try existing.error == nil && existing.settings.runningInput == .interrupt && existing.settings.goalMaximumTurns == 100 && existing.settings.slashMenuPresentation == .recent && Data(contentsOf: previousFile) == previousBytes
            let slashDirectory = output.appendingPathComponent("slash-general"); try FileManager.default.createDirectory(at: slashDirectory, withIntermediateDirectories: false)
            var slashLegacy = baseline; slashLegacy.removeValue(forKey: "artifactLocation"); slashLegacy["slashMenuPresentation"] = "collapsed"
            let slashBytes = try JSONSerialization.data(withJSONObject: slashLegacy), slashFile = slashDirectory.appendingPathComponent("general.json"); try slashBytes.write(to: slashFile)
            let slashExisting = AgentGeneralSettings(directory: slashDirectory); try slashExisting.save(slashExisting.settings)
            checks["ExistingSlashPreferencesLoadWithoutRewritingOrResetting"] = try slashExisting.error == nil && slashExisting.settings.artifactLocation == .workspace && slashExisting.settings.slashMenuPresentation == .collapsed && Data(contentsOf: slashFile) == slashBytes
            for (name, key, bad) in [("version", "version", 9 as Any), ("policy", "completionNotifications", "sometimes" as Any), ("boolean", "menuBarIcon", "yes" as Any), ("unknown", "extra", true as Any), ("input", "runningInput", "later" as Any), ("turns", "goalMaximumTurns", 4 as Any), ("null-input", "runningInput", NSNull() as Any), ("null-turns", "goalMaximumTurns", NSNull() as Any), ("slash", "slashMenuPresentation", "other" as Any), ("null-slash", "slashMenuPresentation", NSNull() as Any), ("artifact", "artifactLocation", "external" as Any), ("null-artifact", "artifactLocation", NSNull() as Any)] {
                let directory = output.appendingPathComponent("invalid-" + name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                var raw = baseline; raw[key] = bad; let bytes = try JSONSerialization.data(withJSONObject: raw), target = directory.appendingPathComponent("general.json"); try bytes.write(to: target)
                let invalid = AgentGeneralSettings(directory: directory); refused = false; do { try invalid.save(.init()) } catch { refused = true }
                checks["Invalid-" + name + "PreservesOriginalBytes"] = try refused && invalid.error != nil && Data(contentsOf: target) == bytes
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("general.json"), withDestinationURL: file)
            checks["SymlinkConfigurationRejected"] = AgentGeneralSettings(directory: linked).error != nil
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func controls(_ owner: ControlWindow) throws -> [NSControl] {
                guard let root = owner.window?.contentView else { throw PetError("缺少设置窗口") }; return descendants(root).compactMap { $0 as? NSControl }.filter { $0.identifier?.rawValue.hasPrefix("general-") == true && !$0.isHiddenOrHasHiddenAncestor }
            }
            func switchValue(_ id: String, _ owner: ControlWindow) throws -> NSSwitch {
                guard let view = try controls(owner).first(where: { $0.identifier?.rawValue == id }) as? NSSwitch else { throw PetError("缺少常规开关：" + id) }; return view
            }
            guard control.showSettingsCategory("general"), let window = control.window else { throw PetError("常规页面未打开") }
            let appMenu = NSApp.mainMenu, toggle = try switchValue("general-menu-bar-icon", control)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); await wait(0.05)
            toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
            await wait(0.05)
            checks["HiddenMenuRetainsDockAndApplicationMenus"] = !service.settings.menuBarIcon && statusItem == nil && NSApp.activationPolicy() == .regular && NSApp.mainMenu === appMenu
            toggle.state = .on; _ = toggle.sendAction(toggle.action, to: toggle.target)
            await wait(0.05)
            checks["RestoreMenuRecreatesActualStatusItem"] = service.settings.menuBarIcon && statusItem?.isVisible == true && NSApp.activationPolicy() == .accessory
            checks["ChangingMenuVisibilityRetainsActiveOwner"] = NSApp.isActive && window.isKeyWindow
            openTaskWindow(b, from: control); guard let second = additionalTaskWindows.last, second.showSettingsCategory("general") else { throw PetError("第二个设置窗口未打开") }
            let question = try switchValue("general-question-notifications", control); question.state = .off; _ = question.sendAction(question.action, to: question.target)
            checks["ExistingSettingsWindowsUpdateImmediately"] = try !service.settings.questionNotifications && switchValue("general-question-notifications", second).state == .off
            let saved = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            question.state = .on; _ = question.sendAction(question.action, to: question.target)
            checks["FailedVisibleSaveRollsBackControlsInBothWindows"] = try question.state == .off && switchValue("general-question-notifications", second).state == .off && Data(contentsOf: file) == saved
            for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                window.makeKeyAndOrderFront(nil); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                let field = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "常规设置保存状态" }
                checks[name + "FailedSaveFeedbackIsVisibleWithoutScrolling"] = field.map { $0.stringValue.contains("只读") && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height > 0 && $0.visibleRect.height >= $0.bounds.height - 1 } == true
            }
            window.setContentSize(NSSize(width: 1200, height: 774))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); question.state = .on; _ = question.sendAction(question.action, to: question.target)
            checks["VisibleRetrySavesPreference"] = service.settings.questionNotifications && AgentGeneralSettings(directory: store.directory).settings == service.settings
            guard let input = try controls(control).first(where: { $0.identifier?.rawValue == "general-running-input" }) as? NSPopUpButton,
                  let turns = try controls(control).first(where: { $0.identifier?.rawValue == "general-goal-turns" }) as? NSPopUpButton,
                  let slash = try controls(control).first(where: { $0.identifier?.rawValue == "general-slash-menu" }) as? NSPopUpButton,
                  let artifact = try controls(control).first(where: { $0.identifier?.rawValue == "general-artifact-location" }) as? NSPopUpButton else { throw PetError("缺少任务与工具设置") }
            input.selectItem(at: 1); _ = input.sendAction(input.action, to: input.target)
            turns.selectItem(at: 0); _ = turns.sendAction(turns.action, to: turns.target)
            checks["TaskPreferencesSaveAndReachActualRuntime"] = service.settings.runningInput == .interrupt && service.settings.goalMaximumTurns == 5 && runtime.taskSettings() == service.settings
            checks["TaskPreferencePopupsSyncAcrossExistingWindows"] = try (controls(second).first(where: { $0.identifier?.rawValue == "general-running-input" }) as? NSPopUpButton)?.selectedItem?.title == "插话" && (controls(second).first(where: { $0.identifier?.rawValue == "general-goal-turns" }) as? NSPopUpButton)?.selectedItem?.title == "5"
            slash.selectItem(at: 2); _ = slash.sendAction(slash.action, to: slash.target)
            checks["SlashPresentationSavesAndSyncsExistingWindows"] = try service.settings.slashMenuPresentation == .collapsed && (controls(second).first(where: { $0.identifier?.rawValue == "general-slash-menu" }) as? NSPopUpButton)?.selectedItem?.title == "收起插件内容" && AgentGeneralSettings(directory: store.directory).settings == service.settings
            artifact.selectItem(at: 1); _ = artifact.sendAction(artifact.action, to: artifact.target)
            checks["ArtifactLocationSavesAndSyncsExistingWindows"] = try service.settings.artifactLocation == .window && (controls(second).first(where: { $0.identifier?.rawValue == "general-artifact-location" }) as? NSPopUpButton)?.selectedItem?.title == "新窗口查看" && AgentGeneralSettings(directory: store.directory).settings == service.settings
            for (label, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
                let views = try controls(control)
                checks[label + "NativeControlsFitAndHaveNoAmbiguousLayout"] = views.count == 8 && views.allSatisfy { !$0.hasAmbiguousLayout && $0.bounds.width > 20 } && window.contentView?.bounds.size == size
                checks[label + "GeneralPageHasNoDuplicateSave"] = !descendants(window.contentView!).contains { ($0 as? NSButton)?.title == "保存" && !$0.isHiddenOrHasHiddenAncestor }
            }
            window.setContentSize(NSSize(width: 1200, height: 774)); control.show(tab: "chat"); window.makeKeyAndOrderFront(nil); await wait(0.05)
            checks["TaskFocusExcludesSettingsPages"] = control.hasTaskFocus && !second.hasTaskFocus
            _ = control.showSettingsCategory("general"); checks["FocusedSettingsIsNotFocusedConversation"] = !control.hasTaskFocus
            second.window?.orderOut(nil); window.orderOut(nil)
            let reopenTask = inputControl.agentTaskID
            checks["ReopenIgnoresVisiblePetWhenTaskWindowsAreHidden"] = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) && taskControls.contains { $0.window?.isVisible == true && $0.agentTaskID == reopenTask }
            checks["OriginalTasksAndDraftsRemainByteExact"] = try originals.allSatisfy { try encoder.encode(tasks.task($0.key)!) == $0.value }
            let notifications = automationNotifications, oldPreferences = notifications.preferences, oldFocus = notifications.isTaskFocused, oldRecord = notifications.taskRecord
            var captured: [UNNotificationRequest] = [], preferences = service.settings, focused = false
            notifications.preferences = { preferences }; notifications.isTaskFocused = { _ in focused }; notifications.taskRecord = nil; notifications.postForCheck = { captured.append($0) }
            defer { notifications.preferences = oldPreferences; notifications.isTaskFocused = oldFocus; notifications.taskRecord = oldRecord; notifications.postForCheck = nil }
            var record = tasks.task(a)!; record.status = .completed
            for policy in AgentCompletionNotification.allCases {
                for isFocused in [false, true] {
                    preferences.completionNotifications = policy; focused = isFocused; let count = captured.count
                    record.messages = [AgentMessage(role: "assistant", content: "原生通知元数据检查，未调用模型")]
                    notifications.completed(record); notifications.completed(record); await wait(0.02)
                    checks["CompletionPolicy-" + policy.rawValue + "-" + String(isFocused)] = captured.count - count == (policy.allows(focused: isFocused) ? 1 : 0)
                }
            }
            for name in ["ask_user", "write_file"] {
                for enabled in [false, true] {
                    preferences.questionNotifications = enabled; preferences.approvalNotifications = enabled
                    let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: "{}"), count = captured.count
                    record.status = .waiting; record.pendingCalls = [call]; record.approvals = [AgentApproval(call: call, reason: "原生通知事件", workspace: nil)]
                    notifications.pending(record); notifications.pending(record); await wait(0.02)
                    checks["PendingPolicyAndDedup-" + name + "-" + String(enabled)] = captured.count - count == (enabled ? 1 : 0)
                }
            }
            preferences.questionNotifications = true
            let count = captured.count
            for _ in 0..<2 { for key in ["first", "second"] { notifications.question(record, requestID: key, isCurrent: { true }) } }; await wait(0.02)
            checks["ConcurrentMCPQuestionsAreIndividuallyDeduplicated"] = captured.count == count + 2
            let prior = captured.count; notifications.question(record, requestID: "expired", isCurrent: { false }); await wait(0.02)
            checks["ExpiredQuestionDoesNotNotify"] = captured.count == prior
            preferences.completionNotifications = .always; notifications.taskRecord = { _ in nil }; record.status = .completed; record.messages = [AgentMessage(role: "assistant", content: "未持久化的过期元数据")]
            notifications.completed(record); await wait(0.02); checks["RemovedTaskDoesNotNotify"] = captured.count == prior
            notifications.taskRecord = nil; var archived = record; archived.archived = true; notifications.completed(archived); await wait(0.02)
            checks["ArchivedTaskDoesNotNotify"] = captured.count == prior
            let automation = AgentAutomationRun(automationID: "native-notice", name: "原生自动化通知", scheduled: Date(), trigger: "check", taskID: a, status: .completed)
            preferences.completionNotifications = .never; notifications.post(automation); await wait(0.02)
            checks["AutomationRespectsDisabledCompletionNotification"] = captured.count == prior
            preferences.completionNotifications = .always; notifications.post(automation); await wait(0.02)
            checks["AutomationUsesSameTaskTargetAndPolicy"] = captured.count == prior + 1 && captured.last?.identifier == automation.id + ".completed"
            let routed = tasks.create(title: "原生权限请求路由", mode: .ask), call = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{}")
            tasks.update(routed) { $0.status = .waiting; $0.pendingCalls = [call]; $0.approvals = [AgentApproval(call: call, reason: "只验证通知路由，不执行工具", workspace: nil)] }
            notifications.taskRecord = oldRecord; preferences.approvalNotifications = true
            runtime.onChange?(routed); runtime.onChange?(routed); await wait(0.02)
            checks["ActualRuntimeChangeCallbackRoutesPendingRequestOnce"] = captured.count == prior + 2 && captured.last?.content.userInfo["task_id"] as? String == routed
            checks["NotificationMetadataTargetsTaskWithoutConversationBody"] = captured.allSatisfy { [a, routed].contains($0.content.userInfo["task_id"] as? String ?? "") && !$0.content.body.contains("原生通知元数据") && $0.content.sound != nil }
            notifications.postForCheck = nil; refused = false
            do { _ = try await notifications.request() } catch { refused = true }
            checks["IndependentCheckCannotRequestOSPermission"] = refused
            refused = false; do { try await notifications.test(taskID: a) } catch { refused = true }
            checks["IndependentCheckCannotDeliverOSNotification"] = refused
            checks["NoModelMessagesOrReceiptsWereSaved"] = tasks.tasks.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["capturedNativeRequests"] = captured.map { ["id": $0.identifier, "body": $0.content.body, "taskID": $0.content.userInfo["task_id"] as? String ?? ""] }
            for (key, value) in try await checkTaskExecutionPreferences(output) { checks["Execution-" + key] = value }
            for (key, value) in try await checkSlashMenu(output) { checks["Slash-" + key] = value }
            checks["SlashFixtureCreatesNoModelRepliesOrReceipts"] = tasks.tasks.allSatisfy { !$0.messages.contains(where: \.isReply) && ($0.modelReceipts ?? []).isEmpty }
            report["boundary"] = "Native metadata copies exercise notification policy and request construction. Execution preferences additionally exercise actual local command cancellation and persisted goal budgets in a separate isolated profile. No model answer, provider request or delivered OS notification is claimed."
            report["success"] = checks.count >= 35 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("general-settings-report.json"))
    }
}
