import AppKit
import WebKit

@MainActor extension AppDelegate {
    func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { self.diagnostics.append(error.localizedDescription) }
                continuation.resume(returning: value)
            }
        }
    }
    func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func capturePet(_ file: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            web.takeSnapshot(with: nil) { image, error in
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: file) }
                if let error { self.diagnostics.append(error.localizedDescription) }
                continuation.resume()
            }
        }
    }
    func runSelfCheck() async {
        guard let output = checkDirectory else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let attentionLiveUI = CommandLine.arguments.contains("--attention-live-ui")
        if CommandLine.arguments.contains("--manual-ui") || attentionLiveUI {
            // Normal manual acceptance blocks transmission; live attention requires its separate bounded authorization and ledger.
            var requests = 0
            do {
                ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
                if attentionLiveUI {
                    let budget = try prepareAttentionLiveUI(output); requests = budget.used
                    runtime.modelRequestCheck = { try budget.request(); requests = budget.used }
                } else { runtime.modelRequestCheck = { requests += 1; throw PetError("本轮手动窗口检查禁止模型请求") } }
                if CommandLine.arguments.contains("--task-window-fixtures") { try await prepareTaskWindowCheck(output) }
                if CommandLine.arguments.contains("--attention-fixtures") { try await prepareAttentionCheck(output) }
                if CommandLine.arguments.contains("--task-search-fixtures") { try prepareTaskSearchCheck(output) }
                if CommandLine.arguments.contains("--round-rollback-fixtures") { let fixture = try await prepareRoundRollbackCheck(output); control.showAgentTask(fixture.taskID) }
                let pid = String(getpid()), binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
                func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent(name), options: .atomic) }
                control.show(tab: "chat")
                try write(["appPID": getpid(), "binaryHash": hash, "modelTransmissionBlocked": !attentionLiveUI, "boundedAttentionLive": attentionLiveUI, "modelRequestsAtStart": requests], "manual-ui-process-" + pid + ".json")
                let deadline = Date().addingTimeInterval(3600); var capture = ""
                while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-manual-ui-" + pid).path) {
                    if let name = try? String(contentsOf: output.appendingPathComponent("capture-manual-ui-" + pid), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                        capture = name; var value = control.organizationSnapshot(); value["appPID"] = getpid(); value["binaryHash"] = hash; value["modelRequests"] = requests
                        value["windows"] = taskControls.map { $0.organizationSnapshot() }
                        value["backgroundTaskIDs"] = tasks.tasks.filter { tasks.hooks.isRunning($0.id) }.map(\.id)
                        value["attention"] = attentionWindow?.checkState() ?? [:]
                        value["fileOpenEvents"] = fileOpenEvents
                        value["fileOpenPending"] = pendingFileOpens.count
                        value["fileOpenImporting"] = fileOpenJob != nil
                        value["tasks"] = tasks.tasks.map { ["id": $0.id, "title": $0.title, "mode": $0.organizationMode.rawValue, "archived": $0.archived, "unread": tasks.organization.isTaskUnread($0.id)] as [String: Any] }
                        try write(value, "native-manual-ui-" + pid + "-" + name + ".json")
                    }; await wait(0.25)
                }
                runtime.stopAll(); try write(["appPID": getpid(), "binaryHash": hash, "modelRequests": requests], "manual-ui-result-" + pid + ".json")
            } catch { try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription, "modelRequests": requests]).write(to: output.appendingPathComponent("manual-ui-error-" + String(getpid()) + ".json")) }
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--video-preview-check") { await runAgentVideoPreviewCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--text-encoding-check") { await runAgentTextEncodingCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--file-conflict-check") { await runAgentFileConflictCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-tree-check") { await runAgentWikiTreeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--project-knowledge-check") { await runAgentProjectKnowledgeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--project-knowledge-sharing-check") { await runAgentProjectKnowledgeSharingCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-views-check") { await runAgentTaskViewCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-records-crash-check") { await runAgentTaskRecordsCrashCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-records-recovery-check") { await runAgentTaskRecordsRecoveryCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-records-check") { await runAgentTaskRecordsCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-archive-check") { await runAgentTaskArchiveCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--repo-wiki-overview-check") { await runAgentRepoWikiOverviewCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--knowledge-editing-check") { await runAgentKnowledgeEditingCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-updates-check") { await runAgentWikiUpdatesCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-generation-check") { await runAgentWikiGenerationCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-citation-check") { await runAgentWikiCitationCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-sharing-check") { await runAgentWikiSharingCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--wiki-plan-check") { await runAgentWikiPlanCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--markdown-table-check") { await runAgentMarkdownTableCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--markdown-edit-check") { await runAgentMarkdownEditingCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--markdown-check") { await runAgentMarkdownCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--knowledge-cards-check") { await runAgentKnowledgeCardCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--knowledge-check") { await runAgentKnowledgeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--reply-policy-check") { await runAgentReplyPolicyCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--round-rollback-check") { await runAgentRoundRollbackCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--edit-resend-check") { await runAgentEditResendCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--side-task-check") { await runAgentSideTaskCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-agent-live-check") { await runAgentPluginAgentLiveCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-rule-check") { await runAgentPluginRuleCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--local-rule-check") { await runAgentRuleCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--instruction-check") { await runAgentInstructionCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-scope-crash-check") { await runAgentPluginScopeCrashCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-scope-recovery-check") { await runAgentPluginScopeRecoveryCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-scope-check") { await runAgentPluginScopeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-update-check") { await runAgentPluginUpdateCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-update-crash-check") { await runAgentPluginUpdateCrashCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-update-recovery-check") { await runAgentPluginUpdateRecoveryCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--rules-live-check") { await runAgentRulesLiveCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--rules-glob-live-check") { await runAgentRulesLiveCheck(output, globOnly: true); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--rules-glob-retry-check") { await runAgentRulesGlobRetryCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--rules-metadata-replay-check") { await runAgentRulesMetadataReplayCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-hook-check") { await runAgentPluginHookCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--plugin-agent-check") { await runAgentPluginAgentCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--attachment-drop-check") { await runAgentAttachmentDropCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--file-open-check") { await runAgentFileOpenCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--side-task-reopen-check") { await runAgentSideTaskReopenCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--side-task-session-check") { await runAgentSideTaskSessionCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--side-task-session-observe") { await runAgentSideTaskSessionObserver(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--side-task-session-recover") { await runAgentSideTaskSessionRecovery(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--round-rollback-crash-check") { await runAgentRoundRollbackCrashCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--round-rollback-recovery-check") { await runAgentRoundRollbackRecoveryCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--terminal-check") { await runAgentTerminalCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--import-check") { await runAgentImportCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--organization-check") { await runAgentOrganizationCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--office-check") { await runAgentOfficeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--canvas-check") { await runAgentCanvasCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--desktop-check") { await runAgentDesktopCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--file-change-check") { await runAgentProjectChangesCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--worktree-creation-check") { await runAgentWorktreeCreationCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--worktree-check") { await runAgentWorktreeCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--git-review-check") { await runAgentGitReviewCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--git-push-check") { await runAgentGitPushCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--git-inspection-check") { await runAgentGitInspectionCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--mcp-content-check") { await runAgentMCPContentCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--task-model-check") { await runAgentTaskModelCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--automation-check") { await runAgentAutomationCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--workbench-check") { await runAgentWorkbenchCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--custom-agent-check") { await runAgentProfileCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--hook-async-check") { await runAgentHookAsyncCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--hook-service-check") { await runAgentHookServiceCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--hook-check") { await runAgentHookCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--mcp-check") { await runAgentMCPCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--extension-check") {
            await runAgentExtensionCheck(output)
            if CommandLine.arguments.contains("--extension-ui-hold") {
                let deadline = Date().addingTimeInterval(240)
                while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--browser-check") {
            if CommandLine.arguments.contains("--browser-visual") { await runAgentBrowserVisualCheck(output) }
            else { await runAgentBrowserCheck(output) }
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--document-check") { await runAgentDocumentCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--live-visuals") {
            var report: [String: Any]
            do {
                guard CommandLine.arguments.contains("--live-agent") else { throw PetError("真实双图验收需要 --live-agent") }
                report = try await checkAttachmentVision(output)
            } catch { report = ["success": false, "error": error.localizedDescription] }
            report["validationContextLimit"] = store.preferences.contextLimit; report["validationOutputLimit"] = store.preferences.outputLimit
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("visual-report.json"))
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--wiki-ui-check") {
            ensureAgent(); var checks: [String: Bool] = [:]
            if let tasks = agentStore, let task = tasks.tasks.first(where: { $0.kind == "wiki" && $0.status == .completed }) {
                let records = AgentRecordWindow(store: tasks, taskID: task.id, section: 6); checks.merge(records.checkWiki(output)) { _, value in value }; records.close()
                let knowledge = AgentKnowledgeWindow(store: tasks, taskID: task.id); checks.merge(await knowledge.checkLayout(query: "海盐", output: output)) { _, value in value }; knowledge.close()
            } else { checks["existingVerifiedWikiFixture"] = false }
            let report: [String: Any] = ["success": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks, "scope": "Native readers use the previous real-model public Wiki fixture. No model, microphone or TTS calls."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-ui-report.json")); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--index-check") { await runAgentIndexCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--git-check") { await runAgentGitCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--context-check") { await runAgentContextCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--agent-ui-check") {
            var checks = await control.checkAgentLayout(output)
            var result: [String: Any] = [:]
            if CommandLine.arguments.contains("--live-web") {
                do {
                    let fetched = try await AgentWeb.fetch("https://docs.qoder.com/qoder/overview")
                    checks["realWebFetchWithSource"] = fetched.text.contains("Qoder") && fetched.sources.contains("https://docs.qoder.com/qoder/overview")
                    let search = try await AgentWeb.search("DeepSeek")
                    checks["realWebSearchWithSources"] = search.sources.contains { URL(string: $0)?.host == "www.deepseek.com" || URL(string: $0)?.host == "api-docs.deepseek.com" }
                    result["webSources"] = fetched.sources + search.sources
                } catch { result["webError"] = error.localizedDescription; checks["realWebTools"] = false }
            }
            result["success"] = checks.values.allSatisfy { $0 }; result["checks"] = checks
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("agent-ui-report.json")); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--agent-check") { await runAgentCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--screen-check") { await runScreenCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--stop-check") { await runStopCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--settings-check") {
            let report = await control.checkSettings(output)
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: output.appendingPathComponent("settings-report.json")); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--size-check") {
            let resize = await checkResize()
            let data = try? JSONSerialization.data(withJSONObject: resize, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: output.appendingPathComponent("resize-report.json")); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--voice-check") { await runVoiceCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--drag-check") { await runDragCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--feedback-check") { await runFeedbackCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--mic-check") { await runMicrophoneCheck(output); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--conversation-check") { await runConversationCheck(output); NSApp.terminate(nil); return }
        await wait(2.0)
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        let profiling = CommandLine.arguments.contains("--profile")
        func phase(_ name: String) {
            if profiling { try? Data(name.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        }
        phase("idle"); if profiling { await wait(7) }
        let before = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        checks["rendererReady"] = (before["frames"] as? Int ?? 0) > 10
        checks["nativeCompactMesh"] = before["compact"] as? Bool == true && (before["triangles"] as? Int ?? 999999) < 60_000
        checks["transparentWindow"] = !pet.isOpaque && pet.backgroundColor?.alphaComponent == 0
        let css = await evaluate("getComputedStyle(document.documentElement).backgroundColor") as? String ?? ""
        checks["transparentPage"] = css == "rgba(0, 0, 0, 0)"
        checks["mouseMonitorAvailable"] = globalMouse != nil && localMouse != nil
        checks["opaqueHit"] = await evaluate("window.petPointerAt(170, 240)") as? Bool == true
        checks["transparentPassThrough"] = await evaluate("window.petPointerAt(2, 2)") as? Bool == false
        _ = await evaluate("window.petPointerLeave()")
        lastPointerQuery = 0
        updatePointer(at: NSPoint(x: pet.frame.minX - 360, y: pet.frame.maxY + 80))
        await wait(0.65)
        let outside = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        let gaze = outside["pointer"] as? [Double] ?? []
        let expression = outside["expression"] as? [String: Any] ?? [:]
        let head = expression["head"] as? [Double] ?? []
        checks["desktopGazeOutsideWindow"] = gaze.count == 2 && gaze[0] < -0.3 && gaze[1] > 0.2
            && head.count == 3 && head[1] < -0.2 && pet.ignoresMouseEvents
        report["desktopPointer"] = outside
        await capturePet(output.appendingPathComponent("pet.png"))
        playDemo(); phase("speaking"); await wait(profiling ? 5 : 1.4)
        let speaking = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        checks["nativeAudioPlayback"] = player?.isPlaying == true
        checks["audioDrivenMouth"] = speaking["speaking"] as? Bool == true && (speaking["peakVolume"] as? Double ?? 0) > 0.03
        await capturePet(output.appendingPathComponent("speaking.png")); stopSpeech(); bubble?.orderOut(nil)
        pet.orderOut(nil); updateVisibility(); await wait(0.3)
        phase("hidden")
        let hiddenA = await evaluate("window.whaleDiagnostics().frames") as? Int ?? -1
        await wait(profiling ? 7 : 0.7)
        phase("verification")
        let hiddenB = await evaluate("window.whaleDiagnostics().frames") as? Int ?? -2
        checks["hiddenStopsRendering"] = hiddenA == hiddenB
        pet.orderFrontRegardless(); updateVisibility(); await wait(0.6)
        let resumed = await evaluate("window.whaleDiagnostics().frames") as? Int ?? 0
        checks["showResumesRendering"] = resumed > hiddenB
        do {
            try store.savePreferences()
            let data = try Data(contentsOf: store.directory.appendingPathComponent("settings.json"))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            checks["settingsPersistWithoutSecrets"] = json["model"] as? String == store.preferences.model
                && !json.keys.contains(where: { $0.lowercased().contains("key") })
        } catch { diagnostics.append(error.localizedDescription); checks["settingsPersistWithoutSecrets"] = false }
        control.show(tab: "settings"); await wait(0.3)
        if let view = control.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: output.appendingPathComponent("settings.png")) }
        }
        report["success"] = checks.values.allSatisfy { $0 } && diagnostics.isEmpty
        report["checks"] = checks; report["render"] = before; report["speech"] = speaking
        report["errors"] = diagnostics; report["architecture"] = "AppKit + system WKWebView; one web view, native controls and audio"
        report["liveAI"] = "Not tested: no user provider key configured. Demo uses existing MiniMax audio."
        phase("finished")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
        NSApp.terminate(nil)
    }
    func runDragCheck(_ output: URL) async {
        // Isolate the controlled trajectory from the user's real cursor.
        if let globalMouse { NSEvent.removeMonitor(globalMouse); self.globalMouse = nil }
        if let localMouse { NSEvent.removeMonitor(localMouse); self.localMouse = nil }
        store.preferences.scale = 0.7587016672327899; applyPreferences(); await wait(1.0)
        let initialFrame = pet.frame
        let initial = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        guard initial["visible"] as? Bool == true, (initial["frames"] as? Int ?? 0) > 5 else {
            let blocked: [String: Any] = ["success": false, "blocked": "Window is not visible; unlock the Mac and uncover the pet before native drag verification.", "initial": initial]
            if let data = try? JSONSerialization.data(withJSONObject: blocked, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("drag-report.json"), options: .atomic)
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        pendingPress = (NSPoint(x: mouse.x - 36, y: mouse.y), initialFrame.origin, motionTranslation, true)
        beginDrag(); moveDrag(to: mouse)
        let latePress = dragged && abs(pet.frame.minX - initialFrame.minX - 36) < 1
        endDrag(); pet.setFrame(initialFrame, display: true); motionTranslation = .zero
        pendingPress = (mouse, initialFrame.origin, .zero, true)
        beginDrag(); moveDrag(to: mouse)
        let returnedPress = dragged
        endDrag()
        beginDrag(); let origin = dragOrigin!.mouse
        var peakAngle = 0.0, peakInertia = 0.0
        for i in 1...60 {
            let t = Double(i) / 60
            moveDrag(to: NSPoint(x: origin.x - 150 * (1 - cos(t * .pi)) / 2,
                                y: origin.y + 45 * sin(t * .pi)))
            await wait(1.0 / 60)
            if i % 6 == 0 {
                let values = await evaluate("window.whaleDiagnostics().drag") as? [String: Any] ?? [:]
                peakAngle = max(peakAngle, values["peakAngle"] as? Double ?? 0)
                peakInertia = max(peakInertia, values["peakInertia"] as? Double ?? 0)
            }
        }
        let held = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        await capturePet(output.appendingPathComponent("held.png")); endDrag()
        await wait(0.18); await capturePet(output.appendingPathComponent("release.png"))
        await wait(2.2)
        let released = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
        let drag = held["drag"] as? [String: Any] ?? [:]
        let end = released["drag"] as? [String: Any] ?? [:]
        let expression = released["expression"] as? [String: Any] ?? [:]
        let suspension = expression["suspension"] as? [String: Any] ?? [:]
        let checks: [String: Bool] = [
            "lateBridgeRetainsPhysicalPress": latePress,
            "returningToPressStillCountsAsDrag": returnedPress,
            "nativeWindowMoved": abs(pet.frame.minX - initialFrame.minX) > 80,
            "nativeMotionReachedRenderer": (drag["motionEvents"] as? Int ?? 0) >= 40,
            "heldReachesAnimation": drag["held"] as? Bool == true,
            "visibleSuspension": peakAngle > 0.035,
            "visibleHairInertia": peakInertia > 0.06,
            "physicalReleaseClearsHold": dragOrigin == nil && end["held"] as? Bool == false,
            "recoilSettles": abs(suspension["angle"] as? Double ?? 1) < 0.01 && abs(suspension["inertia"] as? Double ?? 1) < 0.01,
            "renderBudgetUnchanged": held["drawCalls"] as? Int == 2 && (held["triangles"] as? Int ?? 999999) < 60000,
        ]
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 } && diagnostics.isEmpty,
            "checks": checks, "scale": store.preferences.scale, "initial": initial, "held": held, "released": released,
            "peakAngle": peakAngle, "peakInertia": peakInertia, "errors": diagnostics,
            "scope": "Controlled native window movement through the production host/renderer bridge, at the user's small size; no synthetic OS mouse events."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("drag-report.json"), options: .atomic)
        }
    }
    func runVoiceCheck(_ output: URL) async {
        var events: [String] = [], utterances: [String] = [], checks: [String: Bool] = [:]
        let wake = VoiceWake()
        wake.onEvent = { event in
            switch event {
            case .woke: events.append("woke")
            case .utterance(let text): utterances.append(text)
            case .partial(let text): events.append("partial: " + text)
            case .state(let text): events.append("state: " + text)
            case .stopped(let text, _): events.append("stopped: " + text)
            case .failure(let text): events.append("error: " + text)
            }
        }
        let phrase = WakePhrase(text: "小鲸小鲸")
        checks["wakePhraseStripsPrefix"] = phrase.command(in: "小鲸，小鲸，今天星期几？") == "今天星期几？"
        checks["homophoneWake"] = phrase.command(in: "小精小精，今天天气如何") == "今天天气如何"
        checks["unaddressedSpeechIgnored"] = phrase.command(in: "今天星期几？") == nil
        var fixtures: [[String: Any]] = []
        for name in ["no-wake", "near-wake", "wake-command"] {
            events = []; utterances = []
            do {
                let fixture = output.deletingLastPathComponent().appendingPathComponent(name + ".aiff")
                try await wake.replayForCheck(fixture, phrase: phrase.text)
                let stats = await wake.diagnosticsForCheck()
                if name == "wake-command" {
                    checks["realOfflineSpeechWake"] = events.contains("woke") && stats["keywordHits"] == 1
                    checks["realOfflineSpeechCommand"] = utterances.count == 1 && utterances[0].contains("星期几")
                        && !utterances[0].contains("小鲸") && stats["asrStarts"] == 1
                } else {
                    checks[name + "SuppressesASR"] = !events.contains("woke") && utterances.isEmpty && stats["asrStarts"] == 0
                }
                fixtures.append(["name": name, "stats": stats, "events": events, "utterances": utterances])
            } catch { checks[name + "AudioProcessed"] = false; fixtures.append(["name": name, "error": error.localizedDescription]) }
        }
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 } && checks["realOfflineSpeechCommand"] == true,
            "checks": checks, "fixtures": fixtures, "backend": "sherpa-onnx 2.0.1 keyword spotting + Apple on-device ASR after wake",
            "scope": "Real keyword and speech inference on local Chinese spoken fixtures, through production audio gating and turn assembly; no live model/TTS provider calls. Microphone capture is verified separately in the installed app."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("voice-report.json"), options: .atomic)
        }
    }
    func runFeedbackCheck(_ output: URL) async {
        await wait(0.8)
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func captureBubble(_ name: String) {
            if let view = bubble?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        showBubble("我在，讲吧"); captureBubble("short-bubble")
        let short = bubble?.frame.size ?? .zero
        showBubble("好"); let tiny = bubble?.frame.size ?? .zero
        showBubble("我在呢。今天也陪你一起摸鱼，累了就歇一会儿吧。窗外的天气看起来不错，要不要先喝口水，再继续刚才的事情？")
        captureBubble("wrapped-bubble"); let long = bubble?.frame.size ?? .zero
        checks["shortBubbleFitsText"] = short.width > tiny.width && short.width < 140 && short.height <= 44
        checks["longBubbleWraps"] = long.width <= 268 && long.height > short.height
        checks["bubbleStaysOnScreen"] = bubble.map { panel in NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame) } } ?? false
        report["bubbleSizes"] = ["tiny": [tiny.width, tiny.height], "short": [short.width, short.height], "long": [long.width, long.height]]
        voiceEvent(.woke); await wait(0.06)
        checks["wakeChimePlaysLocally"] = wakePlayer?.isPlaying == true
        checks["cueDoesNotStartMouth"] = await evaluate("window.whaleDiagnostics().speaking") as? Bool == false
        report["chimeSeconds"] = wakePlayer?.duration ?? 0
        await wait(0.5); checks["wakeChimeStops"] = wakePlayer?.isPlaying == false
        if CommandLine.arguments.contains("--live-tts") {
            do {
                let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BlueFatFish/settings.json")
                let p = try JSONDecoder().decode(PetPreferences.self, from: Data(contentsOf: file))
                let key = try PetKeychain(service: "com.xjs.bluefatfish.credentials").read("voice")
                let text = "我在呢，现在可以听到我的声音啦。"
                let data = try await CompanionService.speech(text: text, preferences: p, key: key)
                try data.write(to: output.appendingPathComponent("live-minimax.mp3"))
                try beginAudio(data, text: text); await wait(0.9)
                let state = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
                checks["liveMiniMaxPlayback"] = player?.isPlaying == true && (player?.duration ?? 0) > 1
                checks["liveSpeechDrivesMouth"] = state["speaking"] as? Bool == true && (state["peakVolume"] as? Double ?? 0) > 0.035
                report["liveSpeech"] = ["provider": "MiniMax", "model": p.voiceModel, "voice": p.voiceID,
                                       "seconds": player?.duration ?? 0, "bytes": data.count]
                await capturePet(output.appendingPathComponent("speaking.png")); stopSpeech()
            } catch { checks["liveMiniMaxPlayback"] = false; diagnostics.append(error.localizedDescription) }
        }
        report["checks"] = checks; report["errors"] = diagnostics
        report["success"] = checks.values.allSatisfy { $0 } && diagnostics.isEmpty
        report["scope"] = "Actual native bubble layout and local cue playback; --live-tts additionally makes one short MiniMax request and plays it through the production player/mouth bridge. No chat request or live microphone test."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("feedback-report.json"))
        }
    }
    func runMicrophoneCheck(_ output: URL) async {
        let wake = VoiceWake(); var events: [String] = []
        wake.onEvent = { event in
            switch event {
            case .state(let state): events.append(state)
            case .woke: events.append("woke")
            case .failure(let error): events.append(error)
            default: break // Never persist microphone audio or recognized speech.
            }
        }
        wake.configure(enabled: true, phrase: "小鲸小鲸"); await wait(2.5)
        let initial = await wake.diagnosticsForCheck()
        await wake.interruptInputForCheck(notify: true); await wait(1.6)
        let changed = await wake.diagnosticsForCheck()
        await wake.interruptInputForCheck(notify: false); await wait(6.5)
        let stalled = await wake.diagnosticsForCheck()
        wake.stop(); await wait(0.5)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await wait(0.5); let stopped = await wake.diagnosticsForCheck()
        func active(_ values: [String: Int]) -> Bool { values["engineRunning"] == 1 && (values["micBuffers"] ?? 0) > 4 && (0..<1000).contains(values["lastBufferAgeMs"] ?? -1) }
        let checks = ["realMicrophoneBuffers": active(initial),
            "configurationChangeRecovers": active(changed) && (changed["captureRestarts"] ?? 0) > (initial["captureRestarts"] ?? 0),
            "silentEngineStopRecovers": active(stalled) && (stalled["captureRestarts"] ?? 0) > (changed["captureRestarts"] ?? 0),
            "disabledStaysStopped": stopped["enabled"] == 0 && stopped["engineRunning"] == 0 && stopped["captureStarts"] == stalled["captureStarts"]]
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks, "initial": initial,
            "afterConfigurationChange": changed, "afterSilentStop": stalled, "afterDisable": stopped, "events": events,
            "scope": "Real default microphone capture. Stop the actual engine with/without a configuration notification and verify new live buffers after automatic recovery. No audio files, transcripts, chat or TTS requests."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("microphone-report.json"))
        }
    }
    func runStopCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        checks["stopAliases"] = ["停止录音", "请停止聆听。", "别听了", "关闭麦克风", "先关闭语音吧"].allSatisfy(VoiceStopCommand.matches)
        checks["ordinarySpeechAndNegationIgnored"] = ["不要停止录音", "怎么停止录音", "解释一下停止录音是什么意思", "取消订单"].allSatisfy { !VoiceStopCommand.matches($0) }
        let replay = VoiceWake(); var stops: [Double] = [], utterances = 0, errors: [String] = []
        let started = ProcessInfo.processInfo.systemUptime
        replay.onEvent = { event in
            switch event {
            case .stopped: stops.append(ProcessInfo.processInfo.systemUptime - started)
            case .utterance: utterances += 1
            case .failure(let text): errors.append(text)
            default: break
            }
        }
        do {
            let fixture = output.deletingLastPathComponent().appendingPathComponent("stop-with-noise.aiff")
            try await replay.replayForCheck(fixture, phrase: "小鲸小鲸")
            checks["realSpokenStopBeforeNoiseEnds"] = stops.count == 1 && stops[0] < 7
            checks["stopCommandNotSentAsChat"] = utterances == 0
            report["spokenStop"] = ["seconds": stops.first ?? -1, "stats": await replay.diagnosticsForCheck(), "errors": errors,
                "fixture": "小鲸小鲸，请停止录音。 followed immediately by six seconds of continuous noise; real local KWS and Apple ASR."]
        } catch { checks["realSpokenStopBeforeNoiseEnds"] = false; report["speechError"] = error.localizedDescription }
        store.preferences.wakeEnabled = true; voiceWake.configure(enabled: true, phrase: "小鲸小鲸"); await wait(1.5)
        let before = await voiceWake.diagnosticsForCheck()
        voiceWake.listenNow(); await wait(0.25)
        checks["listeningBubbleHasStopButton"] = bubbleStopButton?.isHidden == false && bubble?.ignoresMouseEvents == false && bubbleTimer?.isValid != true
        if let view = bubble?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("stop-bubble.png"))
        }
        bubbleStopButton?.performClick(nil); await wait(0.3)
        let stopped = await voiceWake.diagnosticsForCheck(), messageCount = store.messages.count
        voiceEvent(.partial("旧转写")); voiceEvent(.utterance("旧识别结果")); voiceEvent(.woke)
        refreshVoiceBusy(followUp: true); await wait(0.8)
        let later = await voiceWake.diagnosticsForCheck()
        checks["realMicrophoneWasRunning"] = before["engineRunning"] == 1 && (before["micBuffers"] ?? 0) > 3
        checks["buttonReleasesMicrophoneAndModels"] = stopped["engineRunning"] == 0 && stopped["enabled"] == 0 && stopped["recognizing"] == 0 && stopped["keywordLoaded"] == 0
        checks["lateEventsCannotSubmitOrRestart"] = store.messages.count == messageCount && chatTask == nil && later["captureStarts"] == stopped["captureStarts"] && later["engineRunning"] == 0
        store.preferences.wakeEnabled = true; voiceWake.configure(enabled: true, phrase: "小鲸小鲸"); await wait(1)
        voiceWake.listenNow(); await wait(0.2); await voiceWake.expireListeningForCheck(); await wait(0.3)
        let timeout = await voiceWake.diagnosticsForCheck()
        checks["timeoutReleasesMicrophone"] = timeout["engineRunning"] == 0 && timeout["enabled"] == 0 && !store.preferences.wakeEnabled
        report["microphone"] = ["before": before, "afterButton": stopped, "afterLateEvents": later, "afterDeadline": timeout]
        report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
        report["scope"] = "Independent profile, one real spoken command fixture and real microphone capture. The deadline clock is advanced for the 60-second limit check. No private audio/transcripts recorded; no online model or TTS calls."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("stop-report.json")) }
    }
    func checkResize() async -> [String: Double] {
        let old = store.preferences.scale, before = pet.frame.width
        let actual = setPetScale(1.1); await wait(0.4)
        let result = ["requestedScale": 1.1, "appliedScale": actual, "beforeWidth": before,
            "actualWidth": Double(pet.frame.width), "expectedWidth": 340 * actual,
            "widthError": Double(pet.frame.width) - 340 * actual]
        _ = setPetScale(old); return result
    }
}
