import AppKit

@MainActor extension AppDelegate {
    func runSettingsSaveScopeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], failure: String?, attempts = 0
        var geometry: [String: CGFloat] = [:]
        let settings = store.directory.appendingPathComponent("settings.json")
        let keys = store.directory.appendingPathComponent("credentials.json")
        let files = FileManager.default
        func find<T: NSView>(_ root: NSView?, _ type: T.Type, matching: (T) -> Bool) -> T? {
            guard let root, !root.isHiddenOrHasHiddenAncestor else { return nil }
            if let view = root as? T, matching(view) { return view }
            for child in root.subviews {
                if let view = find(child, type, matching: matching) { return view }
            }
            return nil
        }
        func input<T: NSView>(_ owner: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let view = find(owner.window?.contentView, type, matching: { $0.accessibilityLabel() == label }) else {
                throw PetError("保存范围验收找不到 " + label)
            }
            return view
        }
        func button(_ owner: ControlWindow, _ title: String) throws -> NSButton {
            guard let view = find(owner.window?.contentView, NSButton.self, matching: { $0.title == title }) else {
                throw PetError("保存范围验收找不到 " + title)
            }
            return view
        }
        func open(_ owner: ControlWindow, _ page: String) throws {
            guard owner.showSettingsCategory(page) else { throw PetError("无法进入设置页 " + page) }
            owner.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func edit(_ owner: ControlWindow, _ label: String, _ value: String, selection: NSRange? = nil) throws {
            let field = try input(owner, NSTextField.self, label)
            guard owner.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView else {
                throw PetError("无法编辑 " + label)
            }
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            if let selection { editor.setSelectedRange(selection) }
        }
        func persist(_ owner: ControlWindow) throws {
            try button(owner, "保存").performClick(nil)
            owner.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func message(_ owner: ControlWindow) -> NSTextField? {
            find(owner.window?.contentView, NSTextField.self, matching: { $0.accessibilityLabel() == "设置保存状态" })
        }
        func readback() throws -> PetPreferences {
            try JSONDecoder().decode(PetPreferences.self, from: Data(contentsOf: settings))
        }
        func permissions(_ file: URL, _ value: Int) throws {
            try files.setAttributes([.posixPermissions: value], ofItemAtPath: file.path)
        }
        func position(_ owner: ControlWindow) throws -> CGFloat {
            let save = try button(owner, "保存")
            return save.convert(save.bounds, to: owner.window?.contentView).maxX
        }
        func image(_ owner: ControlWindow, _ name: String) throws {
            guard let view = owner.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw PetError("无法绘制设置窗口")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PetError("无法导出设置窗口") }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, checkDirectory == output,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("保存范围验收需要独立资料")
            }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("保存范围验收禁止模型请求") }
            store.preferences.endpoint = "https://settings-fixture.example.invalid"
            try store.savePreferences()
            try store.keychain.write("PUBLIC_MODEL_BEFORE", account: "chat")
            try store.keychain.write("PUBLIC_VOICE_BEFORE", account: "voice")
            let originalKeys = try Data(contentsOf: keys)
            let a = tasks.create(title: "模型保存 · 问答样例", draft: "原模型任务草稿")
            let b = tasks.create(title: "语音保存 · 问答样例", draft: "原语音任务草稿")
            control.showAgentTask(a)
            let main = control
            try open(main, "model")
            main.refreshPreferences()
            main.window?.appearance = NSAppearance(named: .darkAqua)
            main.window?.setContentSize(NSSize(width: 780, height: 540))
            main.window?.contentView?.layoutSubtreeIfNeeded()
            geometry["narrowClear"] = try position(main)
            try edit(main, "模型 ID", "public-model-new")
            try edit(main, "上下文预算", "16384")
            openTaskWindow(b, from: main)
            guard let other = additionalTaskWindows.last else { throw PetError("另一任务窗口没有打开") }
            try open(other, "voice")
            other.window?.appearance = NSAppearance(named: .aqua)
            other.window?.setContentSize(NSSize(width: 1320, height: 800))
            try edit(other, "音色", "公开音色更新")
            try persist(other)
            try persist(main)
            var saved = try readback()
            checks["modelSaveRetainsVoiceSavedByOtherWindow"] = saved.model == "public-model-new" && saved.contextTokens == 16384 &&
                saved.replyTokens == 512 && saved.voiceID == "公开音色更新"
            checks["neitherPageWritesCredentialsWhenUnedited"] = try Data(contentsOf: keys) == originalKeys
            try open(other, "persona")
            try edit(other, "角色设定", "公开角色设定")
            try persist(other)
            saved = try readback()
            checks["personaSaveRetainsModelAndVoice"] = saved.persona == "公开角色设定" && saved.contextTokens == 16384 && saved.voiceID == "公开音色更新"

            try open(other, "screen")
            let screen = try input(other, NSSwitch.self, "闲置时观察屏幕")
            screen.state = .on
            let beforeInvalidScreen = try Data(contentsOf: settings)
            try persist(other)
            checks["screenRequiresCurrentModelVision"] = try Data(contentsOf: settings) == beforeInvalidScreen &&
                screen.state == .on && message(other)?.stringValue.contains("视觉理解") == true
            screen.state = .off
            try input(other, NSPopUpButton.self, "观察间隔").selectItem(at: 4)
            try edit(main, "回复上限", "1024")
            try persist(main)
            try persist(other)
            saved = try readback()
            checks["screenSaveRetainsNewModelAndPersona"] = saved.screenObservationInterval == 900 && !saved.screenObservationEnabled &&
                saved.replyTokens == 1024 && saved.persona == "公开角色设定"

            try open(main, "desktop")
            try input(main, NSSwitch.self, "窗口置顶").state = .off
            try open(other, "desktop")
            try input(other, NSPopUpButton.self, "桌宠动画").selectItem(at: 2)
            try persist(other)
            try persist(main)
            saved = try readback()
            checks["desktopMergesUneditedAnimationAndKeepsOtherPages"] = !saved.alwaysOnTop && saved.performance == "paused" &&
                saved.screenObservationInterval == 900 && saved.voiceID == "公开音色更新"

            try open(main, "persona")
            try open(other, "persona")
            other.window?.contentView?.layoutSubtreeIfNeeded()
            geometry["wideClear"] = try position(other)
            try edit(main, "角色设定", "另一窗口先保存")
            let selection = NSRange(location: 0, length: 2)
            try edit(other, "角色设定", "冲突草稿 🧭", selection: selection)
            try persist(main)
            try persist(other)
            let persona = try input(other, NSTextField.self, "角色设定")
            checks["sameFieldConflictProtectsSavedTextAndDraft"] = try readback().persona == "另一窗口先保存" &&
                persona.stringValue == "冲突草稿 🧭" && (persona.currentEditor() as? NSTextView)?.selectedRange() == selection &&
                message(other)?.stringValue.contains("另一窗口更改") == true
            geometry["wideConflict"] = try position(other)
            try image(other, "persona-conflict-wide")
            other.refreshPreferences()

            try open(main, "model")
            try edit(main, "模型 ID", "public-model-after-retry")
            try button(main, "更换").performClick(nil)
            try edit(main, "模型 Token", "PUBLIC_MODEL_AFTER")
            let beforeFailure = try Data(contentsOf: settings)
            try permissions(settings, 0o400)
            try persist(main)
            geometry["narrowError"] = try position(main)
            checks["readOnlySettingsProtectsBothFiles"] = try Data(contentsOf: settings) == beforeFailure &&
                Data(contentsOf: keys) == originalKeys && message(main)?.stringValue.contains("只读") == true
            try image(main, "model-save-read-only-narrow")
            try permissions(settings, 0o600)
            try permissions(keys, 0o400)
            try persist(main)
            let currentDraft = try input(main, NSTextField.self, "模型 ID")
            checks["readOnlyCredentialRestoresExactSettingsAndKeepsInput"] = try Data(contentsOf: settings) == beforeFailure &&
                Data(contentsOf: keys) == originalKeys && currentDraft.stringValue == "public-model-after-retry" &&
                store.preferences.model == "public-model-new" && message(main)?.stringValue.contains("API Key 配置为只读") == true
            try permissions(keys, 0o600)
            try persist(main)
            geometry["narrowSaved"] = try position(main)
            let values = try readback()
            checks["retrySavesOnlyScopedPreferencesAndCredential"] = try values.model == "public-model-after-retry" &&
                values.persona == "另一窗口先保存" && values.voiceID == "公开音色更新" && values.screenObservationInterval == 900 &&
                !values.alwaysOnTop && values.performance == "paused" && store.keychain.read("chat") == "PUBLIC_MODEL_AFTER" &&
                store.keychain.read("voice") == "PUBLIC_VOICE_BEFORE"
            checks["saveAndFeedbackShareStableTrailingPositionAcrossStates"] =
                abs((geometry["narrowError"] ?? 0) - (geometry["narrowClear"] ?? 0)) < 1 &&
                abs((geometry["narrowSaved"] ?? 0) - (geometry["narrowClear"] ?? 0)) < 1 &&
                abs((geometry["wideConflict"] ?? 0) - (geometry["wideClear"] ?? 0)) < 1
            checks["originalTasksAndDraftsRemain"] = main.agentTaskID == a && other.agentTaskID == b &&
                tasks.task(a)?.draft == "原模型任务草稿" && tasks.task(b)?.draft == "原语音任务草稿"
            checks["isolatedWindowStateFlushed"] = await flushWorkspaceWindows()
        } catch {
            failure = error.localizedDescription
        }
        if failure != nil || checks.values.contains(false) {
            for owner in taskControls { owner.refreshPreferences() }
        }
        checks["zeroModelRequests"] = attempts == 0
        var report: [String: Any] = ["checks": checks, "geometry": geometry, "modelRequests": attempts,
                                     "appPID": getpid(), "success": failure == nil && checks.values.allSatisfy { $0 }]
        report["error"] = failure
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("settings-save-scope-report.json"), options: .atomic)
        }
    }
}
