import AppKit

@MainActor extension AppDelegate {
    private struct VoiceFixture: Codable {
        let originalTask: String, secondTask: String, originalWindow: String, secondWindow: String
    }

    func runVoiceSettingsRecoveryCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureFile = output.appendingPathComponent("voice-fixture.json")
        let settingsFile = store.directory.appendingPathComponent("settings.json")
        let credentialsFile = store.directory.appendingPathComponent("credentials.json")
        let endpoint = "https://voice-fixture.example.invalid/v1/tts"
        let voiceID = " 公开音色🧭 "
        let secondID = "另一个音色"
        var checks: [String: Bool] = [:], details: [String: Any] = [:], attempts = 0, failure: String?
        func find<T: NSView>(_ view: NSView?, _ type: T.Type, _ test: (T) -> Bool) -> T? {
            guard let view else { return nil }
            if let value = view as? T, !value.isHiddenOrHasHiddenAncestor, test(value) { return value }
            for child in view.subviews { if let match = find(child, type, test) { return match } }
            return nil
        }
        func input<T: NSView>(_ owner: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let value = find(owner.window?.contentView, type, { $0.accessibilityLabel() == label }) else {
                throw PetError("语音验收缺少控件 " + label)
            }
            return value
        }
        func button(_ owner: ControlWindow, _ title: String) throws -> NSButton {
            guard let value = find(owner.window?.contentView, NSButton.self, { $0.title == title }) else {
                throw PetError("语音验收缺少操作 " + title)
            }
            return value
        }
        func edit(_ owner: ControlWindow, _ label: String, _ text: String, selection: NSRange? = nil) throws {
            let field = try input(owner, NSTextField.self, label)
            guard owner.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView else {
                throw PetError("无法编辑语音字段 " + label)
            }
            editor.string = text
            owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            editor.setSelectedRange(selection ?? NSRange(location: text.utf16.count, length: 0))
            field.scrollToVisible(field.bounds)
            owner.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: owner.window))
        }
        func toggle(_ owner: ControlWindow, _ label: String) throws {
            let field = try input(owner, NSSwitch.self, label)
            field.state = field.state == .on ? .off : .on
            if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
        }
        func viewport(_ owner: ControlWindow, width: CGFloat, height: CGFloat, dark: Bool) {
            owner.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            owner.window?.setContentSize(NSSize(width: width, height: height))
            owner.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func render(_ owner: ControlWindow, _ name: String) -> Bool {
            guard let view = owner.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.representation(using: .png, properties: [:]) else { return false }
            do { try image.write(to: output.appendingPathComponent(name + ".png"), options: .atomic); return true }
            catch { return false }
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("语音设置验收需要独立目录")
            }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("语音设置验收禁止模型请求") }
            if stage == "seed" {
                store.preferences.contextTokens = 8192; store.preferences.replyTokens = 512
                try store.savePreferences()
                try store.keychain.write("PUBLIC_FIXTURE_VOICE_KEY", account: "voice")
                let original = try Data(contentsOf: settingsFile), originalKey = try Data(contentsOf: credentialsFile)
                let task = tasks.create(title: "语音设置 · 原任务", draft: "保留原任务输入")
                let second = tasks.create(title: "语音设置 · 另一窗口", draft: "保留另一窗口输入")
                control.showAgentTask(task)
                guard control.showSettingsCategory("voice") else { throw PetError("原语音设置页未打开") }
                control.refreshPreferences()
                viewport(control, width: 1320, height: 800, dark: true)
                try edit(control, "语音接口", "https://")
                checks["incompleteEndpointCanBePreserved"] = control.captureSettingsNavigation()?.voiceDraft?.form.endpoint == "https://"
                try edit(control, "语音接口", endpoint + "?token=PUBLIC_NOT_A_SECRET")
                checks["queryEndpointExcludedFromRecovery"] = control.captureSettingsNavigation()?.voiceDraft == nil
                try edit(control, "语音接口", "https://public:fixture@voice-fixture.example.invalid/v1")
                checks["embeddedCredentialsExcludedFromRecovery"] = control.captureSettingsNavigation()?.voiceDraft == nil
                try edit(control, "语音接口", endpoint)
                try button(control, "更换").performClick(nil)
                try edit(control, "语音 Token", "PUBLIC_UNSAVED_VOICE_KEY")
                checks["unsavedDedicatedCredentialExcludedFromRecovery"] = control.captureSettingsNavigation()?.voiceDraft == nil
                try button(control, "移除").performClick(nil)
                checks["pendingCredentialRemovalExcludedFromRecovery"] = control.captureSettingsNavigation()?.voiceDraft == nil &&
                    (try? Data(contentsOf: credentialsFile)) == originalKey
                control.refreshPreferences()
                try edit(control, "语音接口", endpoint)
                try edit(control, "语音模型", " speech-public ")
                try edit(control, "音色", voiceID)
                try toggle(control, "语音回复"); try toggle(control, "启用语音唤醒")
                let pause = try input(control, NSPopUpButton.self, "停顿等待")
                pause.selectItem(at: 2)
                if let action = pause.action { NSApp.sendAction(action, to: pause.target, from: pause) }
                try edit(control, "唤醒词", "小", selection: NSRange(location: 0, length: 1))
                if let draft = control.captureSettingsNavigation()?.voiceDraft {
                    let serialized = try JSONEncoder().encode(draft)
                    try AgentVoiceSettingsDraft.validateObject(JSONSerialization.jsonObject(with: serialized))
                    var unsafe = try JSONSerialization.jsonObject(with: serialized) as? [String: Any] ?? [:]
                    var form = unsafe["form"] as? [String: Any] ?? [:]; form["voiceKey"] = "PUBLIC_UNKNOWN_FIELD"; unsafe["form"] = form
                    do { try AgentVoiceSettingsDraft.validateObject(unsafe); checks["unknownCredentialFieldRejected"] = false }
                    catch { checks["unknownCredentialFieldRejected"] = true }
                    checks["originalDraftContainsBothSwitchesPauseRawTextAndSelection"] = draft.form.voiceEnabled && draft.form.wakeEnabled &&
                        draft.form.pauseSeconds == 5 && draft.form.voiceID == voiceID && draft.form.model == " speech-public " &&
                        draft.focus == .wakePhrase && draft.selection?.range == NSRange(location: 0, length: 1)
                } else { throw PetError("原语音草稿未生成") }
                checks["originalDraftRenderedWide"] = render(control, "voice-seed-wide")

                openTaskWindow(second, from: control)
                guard let other = additionalTaskWindows.last, other.showSettingsCategory("voice"),
                      let originalWindow = control.workspaceSession?.id, let secondWindow = other.workspaceSession?.id else {
                    throw PetError("另一语音设置窗口未打开")
                }
                try edit(other, "音色", secondID, selection: NSRange(location: 0, length: 2))
                checks["independentVoiceDrafts"] = other.captureSettingsNavigation()?.voiceDraft?.form.voiceID == secondID &&
                    control.captureSettingsNavigation()?.voiceDraft?.form.voiceID == voiceID
                checks["noPreferencesOrCredentialWriteBeforeSave"] = (try? Data(contentsOf: settingsFile)) == original &&
                    (try? Data(contentsOf: credentialsFile)) == originalKey
                let fixture = VoiceFixture(originalTask: task, secondTask: second, originalWindow: originalWindow, secondWindow: secondWindow)
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(VoiceFixture.self, from: Data(contentsOf: fixtureFile))
                control.show(tab: "chat")
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(),
                      let main = taskControls.first(where: { $0.workspaceSession?.id == fixture.originalWindow }),
                      let other = taskControls.first(where: { $0.workspaceSession?.id == fixture.secondWindow }) else {
                    throw PetError("原语音设置窗口未恢复")
                }
                checks["originalTaskOwnershipAndComposerDrafts"] = main.agentTaskID == fixture.originalTask && other.agentTaskID == fixture.secondTask &&
                    tasks.task(fixture.originalTask)?.draft == "保留原任务输入" && tasks.task(fixture.secondTask)?.draft == "保留另一窗口输入"
                if stage == "resume" {
                    main.window?.makeKeyAndOrderFront(nil)
                    await wait(0.15)
                    let recovered = main.captureSettingsNavigation()
                    checks["oldVoiceDraftAndSeparateSecondDraftRestored"] = recovered?.category == "voice" && recovered?.voiceDraft?.form.voiceID == voiceID &&
                        other.captureSettingsNavigation()?.voiceDraft?.form.voiceID == secondID
                    let phrase = try input(main, NSTextField.self, "唤醒词")
                    let save = try button(main, "保存"), retry = try button(main, "继续使用草稿")
                    checks["sameVoiceInputSelectionInNarrowWindow"] = phrase.stringValue == "小" &&
                        (phrase.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 1) &&
                        main.window?.firstResponder === phrase.currentEditor()
                    checks["changedSavedVoiceSettingsDisableOverwrite"] = store.preferences.voiceModel == "changed-while-closed" &&
                        !save.isEnabled && retry.isEnabled
                    main.renderMessages()
                    main.window?.contentView?.layoutSubtreeIfNeeded()
                    let status = try input(main, NSTextField.self, "设置保存状态")
                    checks["taskRefreshKeepsReadableConflictInFooter"] = status.stringValue.contains("原草稿待核对") &&
                        status.visibleRect.width >= 200 && status.visibleRect.height >= 12
                    if let category = find(main.window?.contentView, NSButton.self, { $0.identifier?.rawValue == "settings-category-voice" }) {
                        checks["narrowSidebarShowsCurrentVoiceCategory"] = category.state == .on && category.visibleRect.height >= category.bounds.height - 1
                    } else { checks["narrowSidebarShowsCurrentVoiceCategory"] = false }
                    checks["conflictRenderedAtNarrowSize"] = render(main, "voice-conflict-narrow")
                    let original = try Data(contentsOf: settingsFile), originalKey = try Data(contentsOf: credentialsFile)
                    retry.performClick(nil)
                    checks["explicitRetryKeepsOriginalEditableTextAndSelection"] = save.isEnabled && phrase.stringValue == "小" &&
                        (phrase.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 1)
                    save.performClick(nil)
                    main.renderMessages()
                    checks["invalidWakePhraseKeepsDraftAndOriginalFile"] = main.captureSettingsNavigation()?.voiceDraft?.form.wakePhrase == "小" &&
                        (try? Data(contentsOf: settingsFile)) == original && status.stringValue.contains("唤醒词请用 2–12 个字")
                    guard main.window?.makeFirstResponder(phrase) == true, let editor = phrase.currentEditor() as? NSTextView else {
                        throw PetError("恢复后的唤醒词不可续写")
                    }
                    editor.insertText("小鲸小鲸", replacementRange: editor.selectedRange())
                    main.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: phrase))
                    var latest = store.preferences
                    latest.contextTokens = 16384; latest.replyTokens = 1024
                    latest.model = "public-model-from-other-window"; latest.persona = "其他窗口保存的角色"
                    store.preferences = latest; try store.savePreferences()
                    save.performClick(nil)
                    let saved = try JSONDecoder().decode(PetPreferences.self, from: Data(contentsOf: settingsFile))
                    checks["explicitSaveAppliesAllVoiceChangesAndKeepsOtherSettings"] = saved.voiceEndpoint == endpoint && saved.voiceModel == "speech-public" &&
                        saved.voiceID == voiceID.trimmingCharacters(in: .whitespacesAndNewlines) && saved.wakePhrase == "小鲸小鲸" &&
                        saved.voiceEnabled && saved.wakeEnabled && saved.voicePauseSeconds == 5 && saved.contextTokens == 16384 &&
                        saved.replyTokens == 1024 && saved.model == latest.model && saved.persona == latest.persona
                    checks["savedDraftClearedOtherDraftAndCredentialRemain"] = main.captureSettingsNavigation()?.voiceDraft == nil &&
                        other.captureSettingsNavigation()?.voiceDraft?.form.voiceID == secondID &&
                        (try? Data(contentsOf: credentialsFile)) == originalKey
                    details["narrowSize"] = main.window.map { [Double($0.contentView?.bounds.width ?? 0), Double($0.contentView?.bounds.height ?? 0)] } ?? []
                } else if stage == "saved" {
                    checks["completedDraftDoesNotReappear"] = main.captureSettingsNavigation()?.category == "voice" &&
                        main.captureSettingsNavigation()?.voiceDraft == nil && store.preferences.voiceModel == "speech-public"
                    checks["secondWindowKeepsItsUnsavedVoiceDraftAfterAnotherSave"] = other.captureSettingsNavigation()?.voiceDraft?.form.voiceID == secondID
                    let back = try button(other, "返回对话")
                    let end = Date().addingTimeInterval(5)
                    let timer = Timer(timeInterval: 0.03, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            if let dialog = NSApp.modalWindow?.agentDialog,
                               let discard = find(dialog.view, NSButton.self, { $0.title == "放弃更改" }) {
                                timer.invalidate(); discard.performClick(nil)
                            } else if Date() >= end { timer.invalidate(); NSApp.abortModal() }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
                    back.performClick(nil); timer.invalidate()
                    checks["explicitDiscardReturnsToOriginalSecondTask"] = other.captureSettingsNavigation() == nil && other.agentTaskID == fixture.secondTask
                } else {
                    checks["discardedVoiceDraftDoesNotReappear"] = other.captureSettingsNavigation() == nil && main.captureSettingsNavigation()?.voiceDraft == nil
                    checks["appliedVoiceValuesAndOtherWindowModelRemain"] = store.preferences.voiceID == voiceID.trimmingCharacters(in: .whitespacesAndNewlines) &&
                        store.preferences.contextTokens == 16384 && store.preferences.replyTokens == 1024
                }
            }
            checks["layoutCheckpointFinished"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = attempts == 0
        details["stage"] = stage; details["checks"] = checks; details["pid"] = getpid(); details["modelRequests"] = attempts
        details["success"] = failure == nil && checks.values.allSatisfy { $0 }
        if let failure { details["error"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("voice-settings-report-\(stage).json"), options: .atomic)
        }
        if failure != nil { for owner in taskControls { owner.refreshPreferences() } }
    }
}
