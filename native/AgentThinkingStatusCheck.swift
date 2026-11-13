import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareThinkingStatusUI(_ output: URL, seed: Bool) throws -> [String: String] {
        ensureAgent(); guard let tasks = agentStore else { throw PetError("缺少思考状态验收环境") }
        let file = output.appendingPathComponent("thinking-status-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["coding"], tasks.task(id) != nil else { throw PetError("原思考状态样例不可用") }; control.showAgentTask(id); control.show(tab: "chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("思考状态样例已存在，请重开原目录") }
        let project = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("# Public thinking fixture\n\n仅用本机公开命令检查状态，不是模型输出。\n".utf8).write(to: project.appendingPathComponent("README.md"))
        let coding = tasks.create(title: "编程动效公开样例", workspace: project.path, mode: .agent), general = tasks.create(title: "无工作区问答动效", mode: .ask, workMode: .general), waiting = tasks.create(title: "等待回答公开样例", mode: .ask)
        for id in [coding, general, waiting] { tasks.update(id) { $0.messages = [AgentMessage(role: "user", content: "本机状态检查，不调用模型。")]; $0.draft = "保留未发送的公开草稿 🧭" } }
        let call = AgentToolCall(id: UUID().uuidString, name: "ask_user", arguments: "{\"question\":\"公开等待问题\"}")
        tasks.update(waiting) { $0.status = .waiting; $0.pendingCalls = [call]; $0.approvals = [AgentApproval(call: call, reason: "公开等待问题", workspace: nil)] }
        let ids = ["coding": coding, "general": general, "waiting": waiting, "modelOutputsCreated": "false"]
        try JSONEncoder().encode(ids).write(to: file); control.showAgentTask(coding); control.show(tab: "chat"); return ids
    }
    @discardableResult func startThinkingStatusExecution(_ id: String) throws -> URL {
        guard checkDirectory != nil, ["--thinking-status-check", "--thinking-status-fixtures", "--thinking-status-reopen"].contains(where: CommandLine.arguments.contains),
              let tasks = agentStore, let runtime = agentRuntime, let task = tasks.task(id), !runtime.isBusy(id), task.pendingCalls.isEmpty else { throw PetError("公开执行样例当前不可运行") }
        let cwd = try task.workspace.map { try AgentFiles(workspace: $0).root } ?? tasks.terminalTaskDirectory(id)
        let name = "thinking-" + UUID().uuidString + ".pid", marker = cwd.appendingPathComponent(name)
        let arguments = try JSONSerialization.data(withJSONObject: ["command": "printf '%s' $$ > " + name + "\nexec /bin/sleep 60", "network": false, "timeout_seconds": 65])
        let call = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: arguments, as: UTF8.self))
        tasks.update(id) {
            $0.status = .ready; $0.messages.append(AgentMessage(role: "assistant", content: "", toolCalls: [call], nativeContext: true)); $0.pendingCalls = [call]
            var approval = AgentApproval(call: call, reason: "本轮公开本机进程验收，不是模型工具调用", workspace: task.workspace); approval.decision = "allow"; approval.decidedAt = Date(); $0.approvals.append(approval)
        }
        runtime.start(id)
        // Keep manual acceptance bounded and stop before the runtime could request a model turn.
        Task { @MainActor [weak runtime] in try? await Task.sleep(nanoseconds: 45_000_000_000); if runtime?.store.task(id)?.pendingCalls.first?.id == call.id { runtime?.cancel(id) } }
        return marker
    }
    func thinkingStatusStep(_ step: String, output: URL) throws -> [String: Any] {
        let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("thinking-status-fixtures.json")))
        guard let runtime = agentRuntime else { throw PetError("缺少公开执行样例") }
        if step == "stop" { for key in ["coding", "general"] { if let id = ids[key] { runtime.cancel(id) } }; return ["stopped": true] }
        guard ["coding", "general"].contains(step), let id = ids[step] else { throw PetError("未知的公开执行步骤") }
        let marker = try startThinkingStatusExecution(id); control.showAgentTask(id); control.show(tab: "chat"); control.renderMessages()
        return ["taskID": id, "marker": marker.path, "modelRequests": 0]
    }
    func runThinkingStatusCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少思考状态验收环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("思考状态检查禁止模型请求") }
            defer { runtime.stopAll() }
            let ids = try prepareThinkingStatusUI(output, seed: true), service = thinkingStatus, file = store.directory.appendingPathComponent("thinking-status.json")
            let originalGeneral = try? Data(contentsOf: store.directory.appendingPathComponent("general.json"))
            checks["unopenedThinkingSettingsCreateNoPreviewOrEditor"] = (control.thinkingStatusReadback()["settings"] as? [String: Any])?.isEmpty == true
            checks["defaultsAreSixLoadersAndTwentyBilingualCaptionsWithoutWrite"] = AgentThinkingStatus.Loader.allCases.count == 6 && service.settings.captions == AgentThinkingStatus.defaults && service.settings.captions.count == 20 && service.settings.loader == .matrix && !FileManager.default.fileExists(atPath: file.path)
            checks["isolatedHomeAndSystemDeliveryBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            for loader in AgentThinkingStatus.Loader.allCases { try service.saveLoader(loader); checks["loaderPersists-" + loader.rawValue] = AgentThinkingStatus(directory: store.directory).settings.loader == loader }
            let baseline = try Data(contentsOf: file)
            var max = service.settings.captions; max[0] = .init(zh: String(repeating: "🐳", count: 32), en: String(repeating: "a", count: 64))
            try service.saveCaptions(max, expected: service.settings.captions)
            checks["unicodeLimitUsesReferenceUTF16UnitsAndReopens"] = AgentThinkingStatus(directory: store.directory).settings.captions == max
            checks["currentLanguageChoosesCorrespondingSavedCaption"] = AgentThinkingStatus.text(service.settings, index: 0, language: "en-US") == max[0].en && AgentThinkingStatus.text(service.settings, index: 0, language: "zh-Hans") == max[0].zh
            var empty = max; empty[0] = .init(zh: "", en: "   "); try service.saveCaptions(empty, expected: max)
            checks["emptyFieldsRestoreTheirOwnDefault"] = service.settings.captions == AgentThinkingStatus.defaults
            let raw = try JSONSerialization.jsonObject(with: baseline) as! [String: Any]
            for name in ["unknown", "loader", "count", "caption-key", "type", "length", "newline", "version"] {
                var invalid = raw, captions = raw["captions"] as! [[String: Any]]
                switch name {
                case "unknown": invalid["other"] = true
                case "loader": invalid["loader"] = "spinner"
                case "count": captions.removeLast(); invalid["captions"] = captions
                case "caption-key": captions[0]["other"] = true; invalid["captions"] = captions
                case "type": captions[0]["zh"] = true; invalid["captions"] = captions
                case "length": captions[0]["zh"] = String(repeating: "🐳", count: 33); invalid["captions"] = captions
                case "newline": captions[0]["en"] = "line\nbreak"; invalid["captions"] = captions
                default: invalid["version"] = 2
                }
                let path = output.appendingPathComponent("invalid-" + name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                let bytes = try JSONSerialization.data(withJSONObject: invalid), target = path.appendingPathComponent("thinking-status.json"); try bytes.write(to: target)
                let loaded = AgentThinkingStatus(directory: path); var refused = false; do { try loaded.saveLoader(.bird) } catch { refused = true }
                checks["invalid-" + name + "-preservesBytes"] = try loaded.error != nil && refused && Data(contentsOf: target) == bytes
            }
            let race = AgentThinkingStatus(directory: store.directory); try service.saveLoader(.music); let saved = try Data(contentsOf: file)
            var refused = false; do { try race.saveLoader(.fish) } catch { refused = true }
            checks["externalRevisionConflictPreservesBytes"] = try refused && Data(contentsOf: file) == saved
            let links = output.appendingPathComponent("linked-config"); try FileManager.default.createDirectory(at: links, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("thinking-status.json"), withDestinationURL: file)
            let linked = AgentThinkingStatus(directory: links); refused = false; do { try linked.saveLoader(.bird) } catch { refused = true }
            checks["symlinkConfigurationIsRejectedWithoutTargetChange"] = try refused && linked.error != nil && Data(contentsOf: file) == saved
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func choose(_ title: String, _ action: () -> Bool) -> Bool {
                let timer = Timer(timeInterval: 0.02, repeats: true) { timer in MainActor.assumeIsolated {
                    for candidate in NSApp.windows where candidate.isVisible {
                        if let root = candidate.contentView, let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) { timer.invalidate(); button.performClick(nil); return }
                    }
                } }
                RunLoop.main.add(timer, forMode: .common); defer { timer.invalidate() }; return action()
            }
            func input(_ owner: ControlWindow, _ id: String) throws -> NSControl {
                guard let root = owner.window?.contentView, let result = descendants(root).first(where: { $0.identifier?.rawValue == "thinking-" + id }) as? NSControl else { throw PetError("缺少思考状态控件：" + id) }; return result
            }
            func edit(_ owner: ControlWindow, _ name: String, _ text: String) throws {
                guard let field = try input(owner, name) as? NSTextField else { throw PetError("缺少文案字段") }; field.stringValue = text; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            guard control.showThinkingStatusSettings(), let window = control.window else { throw PetError("思考状态未进入设置内容页") }
            window.makeKeyAndOrderFront(nil); await wait(0.15)
            checks["settingsUseExistingRightContentWithFortyFieldsAndNoSheet"] = descendants(window.contentView!).filter { $0.identifier?.rawValue.hasPrefix("thinking-caption-") == true }.count == 40 && window.attachedSheet == nil && control.thinkingStatusReadback()["heading"] as? String == "思考状态"
            guard let scroll = try input(control, "caption-1-zh").enclosingScrollView, let document = scroll.documentView else { throw PetError("缺少文案滚动页") }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: Swift.max(0, document.bounds.height - scroll.contentView.bounds.height))); scroll.reflectScrolledClipView(scroll.contentView); await wait(0.25)
            checks["scrollingPreviewOutOfSightStopsItsTimer"] = ((control.thinkingStatusReadback()["settings"] as? [String: Any])?["preview"] as? [String: Any])?["animating"] as? Bool == false
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); await wait(0.25)
            checks["returningToPreviewResumesWithoutLayoutReentry"] = ((control.thinkingStatusReadback()["settings"] as? [String: Any])?["preview"] as? [String: Any])?["animating"] as? Bool == true
            try edit(control, "caption-1-zh", "公开自定义中文…"); try edit(control, "caption-1-en", "Public custom status...")
            checks["captionEditsStayUnsavedUntilExplicitSave"] = try Data(contentsOf: file) == saved && (control.thinkingStatusReadback()["settings"] as? [String: Any])?["dirty"] as? Bool == true
            control.show(tab: "chat"); _ = control.showThinkingStatusSettings()
            checks["navigationRetainsUnsentCaptionDraft"] = (try input(control, "caption-1-zh") as? NSTextField)?.stringValue == "公开自定义中文…"
            let picker = try input(control, "loader") as! NSPopUpButton; picker.selectItem(at: 3); _ = picker.sendAction(picker.action, to: picker.target)
            checks["loaderAutosaveDoesNotCommitOrEraseCaptionDraft"] = try service.settings.loader == .fish && service.settings.captions == AgentThinkingStatus.defaults && (input(control, "caption-1-zh") as? NSTextField)?.stringValue == "公开自定义中文…"
            let save = try input(control, "save") as! NSButton; _ = save.sendAction(save.action, to: save.target)
            checks["explicitSavePersistsBothLanguages"] = AgentThinkingStatus(directory: store.directory).settings.captions[0] == .init(zh: "公开自定义中文…", en: "Public custom status...")
            openTaskWindow(ids["coding"]!, from: control); guard let second = additionalTaskWindows.last, second.showThinkingStatusSettings() else { throw PetError("第二个思考设置窗口未打开") }
            try edit(second, "caption-2-en", "Unsent second window..."); try edit(control, "caption-1-zh", "原窗口更新…"); _ = save.sendAction(save.action, to: save.target)
            let secondSave = try input(second, "save") as! NSButton; _ = secondSave.sendAction(secondSave.action, to: secondSave.target)
            checks["concurrentCaptionConflictKeepsSecondDraftAndFirstSave"] = (try input(second, "caption-2-en") as? NSTextField)?.stringValue == "Unsent second window..." && (second.thinkingStatusReadback()["settings"] as? [String: Any])?["error"] as? String != "" && service.settings.captions[0].zh == "原窗口更新…" && service.settings.captions[1] == AgentThinkingStatus.defaults[1]
            guard let secondPanel = descendants(second.window!.contentView!).compactMap({ $0 as? AgentThinkingStatusView }).first else { throw PetError("缺少第二个文案页面") }
            checks["continueEditingCancelsCloseWithoutLosingConflictingDraft"] = !choose("继续编辑", { secondPanel.prepareToClose() }) && secondPanel.dirty
            checks["explicitDiscardClearsOnlySecondUnsentCaptionDraft"] = choose("放弃更改", { secondPanel.prepareToClose() }) && !secondPanel.dirty && service.settings.captions[0].zh == "原窗口更新…"
            second.window?.orderOut(nil)
            let beforeReadonly = try Data(contentsOf: file); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            try edit(control, "caption-3-zh", "失败后保留的文案…"); _ = save.sendAction(save.action, to: save.target)
            checks["readOnlyFailurePreservesDraftAndBytes"] = try Data(contentsOf: file) == beforeReadonly && (input(control, "caption-3-zh") as? NSTextField)?.stringValue == "失败后保留的文案…" && (control.thinkingStatusReadback()["settings"] as? [String: Any])?["dirty"] as? Bool == true
            for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                window.makeKeyAndOrderFront(nil); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                let fields = descendants(window.contentView!).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue.hasPrefix("thinking-caption-") == true }
                checks[name + "-fortyFieldsFitWithoutAmbiguousLayout"] = fields.count == 40 && fields.allSatisfy { !$0.hasAmbiguousLayout && $0.bounds.width >= 40 && $0.convert($0.bounds, to: window.contentView).maxX <= window.contentView!.bounds.maxX }
                checks[name + "-bilingualHeadersAlignWithInputColumns"] = try ["zh", "en"].allSatisfy { language in
                    let header = try input(control, "column-" + language), field = try input(control, "caption-1-" + language)
                    guard let box = field.superview?.superview else { return false }
                    return abs(header.convert(header.bounds, to: window.contentView).minX - box.convert(box.bounds, to: window.contentView).minX) < 1 && abs(header.bounds.width - box.bounds.width) < 1
                }
                checks[name + "-saveFailureVisible"] = descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.accessibilityLabel() == "思考状态保存状态" && $0.stringValue.contains("只读") && !$0.isHiddenOrHasHiddenAncestor }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); _ = save.sendAction(save.action, to: save.target)
            checks["retryPersistsOriginalFailedDraft"] = AgentThinkingStatus(directory: store.directory).settings.captions[2].zh == "失败后保留的文案…"
            try edit(control, "caption-4-zh", String(repeating: "🐳", count: 33))
            checks["oversizedUIInputStaysEditableWithoutSaving"] = !save.isEnabled && (control.thinkingStatusReadback()["settings"] as? [String: Any])?["dirty"] as? Bool == true && service.settings.captions[3] == AgentThinkingStatus.defaults[3]
            try edit(control, "caption-4-zh", AgentThinkingStatus.defaults[3].zh)
            let persistedBeforeReset = try Data(contentsOf: file)
            guard let resetFirst = descendants(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "恢复文案 1" }) else { throw PetError("缺少逐条恢复按钮") }
            resetFirst.performClick(nil)
            checks["rowResetRestoresBothLanguagesOnlyInDraft"] = try (input(control, "caption-1-zh") as? NSTextField)?.stringValue == AgentThinkingStatus.defaults[0].zh && (input(control, "caption-1-en") as? NSTextField)?.stringValue == AgentThinkingStatus.defaults[0].en && Data(contentsOf: file) == persistedBeforeReset
            let resetAll = try input(control, "reset-all") as! NSButton; resetAll.performClick(nil)
            checks["allResetRequiresExplicitSaveAndKeepsSelectedLoader"] = try Data(contentsOf: file) == persistedBeforeReset && save.isEnabled && service.settings.loader == .fish
            _ = save.sendAction(save.action, to: save.target)
            checks["explicitResetSavePersistsTwentyDefaultPairs"] = AgentThinkingStatus(directory: store.directory).settings.captions == AgentThinkingStatus.defaults && service.settings.loader == .fish
            let glyph = AgentThinkingGlyph(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
            var images: [String: [String]] = [:]
            let frames = output.appendingPathComponent("native-loader-frames"); try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: false)
            for loader in AgentThinkingStatus.Loader.allCases {
                glyph.loader = loader; var hashes: [String] = []
                for frame in [0, 1] {
                    glyph.frameNumber = frame; guard let bitmap = glyph.bitmapImageRepForCachingDisplay(in: glyph.bounds) else { throw PetError("动效帧无法绘制") }
                    glyph.cacheDisplay(in: glyph.bounds, to: bitmap); guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PetError("动效帧无法保存") }
                    try data.write(to: frames.appendingPathComponent(loader.rawValue + "-\(frame).png")); hashes.append(AgentFiles.hash(data))
                }
                images[loader.rawValue] = hashes; checks["nativeGlyphActuallyChanges-" + loader.rawValue] = Set(hashes).count == 2
            }
            checks["sixLoaderGlyphsHaveDistinctNativeOutput"] = Set(images.values.compactMap(\.first)).count == 6; report["nativeFrameHashes"] = images
            window.setContentSize(NSSize(width: 1200, height: 774)); control.show(tab: "chat")
            var traces: [[String: Any]] = []
            for key in ["coding", "general"] {
                let id = ids[key]!, marker = try startThinkingStatusExecution(id); control.showAgentTask(id); control.show(tab: "chat"); window.makeKeyAndOrderFront(nil)
                let deadline = Date().addingTimeInterval(4); while Date() < deadline && !FileManager.default.fileExists(atPath: marker.path) { await wait(0.02) }
                let pid = pid_t(try String(contentsOf: marker)) ?? 0; control.renderMessages(); await wait(0.2)
                checks[key + "-actualLocalCommandIsRunningWithoutModel"] = pid > 0 && kill(pid, 0) == 0 && runtime.isExecuting(id) && tasks.task(id)?.status == .running
                let placeholder = AgentMessage(role: "assistant", content: "")
                tasks.update(id) { $0.messages.append(placeholder) }; control.renderMessages()
                checks[key + "-nativeEmptyStreamingPlaceholderDoesNotAddBlankReply"] = (control.conversationDisplayReadback()["messages"] as? [String: [String: Any]])?[placeholder.id] == nil && (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["active"] as? Bool == true
                let before = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["ticks"] as? Int ?? -1; await wait(0.3)
                checks[key + "-visibleRunningIndicatorAdvances"] = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["animating"] as? Bool == true && ((control.thinkingStatusReadback()["indicator"] as? [String: Any])?["ticks"] as? Int ?? 0) > before
                control.checkThinkingMotion(true); let frozen = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["ticks"] as? Int; await wait(0.2)
                checks[key + "-reducedMotionKeepsReadableStaticStatus"] = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["animating"] as? Bool == false && (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["ticks"] as? Int == frozen && ((control.thinkingStatusReadback()["indicator"] as? [String: Any])?["caption"] as? String)?.isEmpty == false
                control.checkThinkingMotion(nil); control.show(tab: "settings"); await wait(0.1)
                checks[key + "-hiddenConversationStopsTimer"] = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["animating"] as? Bool == false
                control.show(tab: "chat"); control.renderMessages(); await wait(0.15)
                checks[key + "-returningConversationResumesTimer"] = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["animating"] as? Bool == true
                runtime.cancel(id); let stopped = Date().addingTimeInterval(4); while Date() < stopped && kill(pid, 0) == 0 { await wait(0.02) }; control.renderMessages(); await wait(0.1)
                checks[key + "-stopEndsActualProcessAndIndicator"] = kill(pid, 0) != 0 && !runtime.isExecuting(id) && tasks.task(id)?.status == .stopped && (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["active"] as? Bool == false && (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["animating"] as? Bool == false
                traces.append(["taskID": id, "commandPID": pid, "marker": marker.path, "final": control.thinkingStatusReadback()])
            }
            control.showAgentTask(ids["waiting"]!); control.renderMessages()
            checks["waitingApprovalCannotShowThinking"] = (control.thinkingStatusReadback()["indicator"] as? [String: Any])?["active"] as? Bool == false
            checks["nativeTasksRetainDraftsAndContainNoModelReplyOrUsage"] = ["coding", "general", "waiting"].allSatisfy { key in guard let task = tasks.task(ids[key]!) else { return false }; return task.draft == "保留未发送的公开草稿 🧭" && !task.messages.contains(where: \.isReply) && (task.modelReceipts ?? []).isEmpty && task.inputTokens == 0 && task.outputTokens == 0 }
            checks["thinkingPreferencesDoNotRewriteGeneralConfiguration"] = (try? Data(contentsOf: store.directory.appendingPathComponent("general.json"))) == originalGeneral
            report["runtimeTraces"] = traces; report["boundary"] = "Native pending-call fixtures run actual bounded local commands through AgentRuntime, including ask mode without a workspace. They create no model responses. Reduced Motion is injected only into the test view, without changing OS settings."
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = attempts; report["modelRequests"] = agentStore?.tasks.reduce(0) { $0 + ($1.modelReceipts?.count ?? 0) } ?? 0
        report["appPID"] = getpid(); report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && attempts == 0
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("thinking-status-report.json"))
        print("thinking status: \(checks.filter { $0.value }.count)/\(checks.count)")
    }
}
