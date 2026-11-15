import AppKit

@MainActor extension AppDelegate {
    struct BrowserRecoveryFixture: Codable {
        var taskID: String, otherID: String, windowID: String, tabID: String, otherWindowID: String
        var base: String, imageHash: String, note: String, oldAction: String
    }
    func runBrowserRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("浏览器恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("browser-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let firstNote = "未添加标注 PUBLIC_BROWSER_NOTE_417", finalNote = "未添加标注 PUBLIC_BROWSER_NOTE_417 最后输入_618"
            let text = "网页草稿 PUBLIC_FORM_417 中文😀"
            func object(_ result: AgentToolResult) throws -> [String: Any] {
                guard let start = result.text.firstIndex(of: "{") else { throw PetError("缺少真实网页结果") }; return try JSONSerialization.jsonObject(with: Data(result.text[start...].utf8)) as! [String: Any]
            }
            func call(_ name: String, _ arguments: [String: Any]) throws -> AgentToolCall { .init(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)) }
            func load(_ f: BrowserRecoveryFixture) throws -> AgentWorkspaceRecovery.LoadedPage {
                guard let value = try journal.loadPage(windowID: f.windowID, pageID: f.tabID, taskID: f.taskID) else { throw PetError("浏览器检查点缺失") }; return value
            }
            func eventually(_ predicate: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline { if predicate() { return true }; await wait(0.05) }; return predicate()
            }
            func inspect(_ browser: AgentBrowserWindow) async throws -> [String: Any] {
                try await browser.web.callAsyncJavaScript("return {url:location.href,note:document.getElementById('note')?.value,checked:document.getElementById('flag')?.checked,choice:document.getElementById('choice')?.value,password:document.getElementById('password')?.value,x:scrollX,y:scrollY,cookie:document.cookie};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
            }
            let fixture: BrowserRecoveryFixture
            if stage == "seed" {
                let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("browser-input.json"))) as! [String: String]
                guard let base = input["url"], let url = URL(string: base), url.host == "127.0.0.1" else { throw PetError("浏览器恢复仅使用独立本机网页") }
                let project = output.appendingPathComponent("public-browser-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try AgentFiles(workspace: project.path).writeData(Data("PUBLIC_BROWSER_PROJECT_417\n".utf8), to: project.appendingPathComponent("README.md"), permissions: 0o644)
                let id = tasks.create(title: "浏览器与未添加标注恢复", workspace: project.path), other = tasks.create(title: "另一窗口的独立网页", mode: .ask)
                tasks.update(id) { $0.draft = "保留主任务输入 PUBLIC_BROWSER_DRAFT_417" }; tasks.update(other) { $0.draft = "保留另一窗口输入 PUBLIC_OTHER_618" }
                control.showAgentTask(id); control.show(tab: "chat")
                let browser = try tasks.browser.show(taskID: id, title: "浏览器与未添加标注恢复")
                _ = try await browser.open(URL(string: base + "first/history")!); _ = try await browser.open(URL(string: base + "first/form")!)
                let initial = try object(await browser.read(offset: 1, query: "网页说明")), firstID = browser.pages[0].id
                guard let field = (initial["elements"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "网页说明" }) else { throw PetError("真实网页缺少说明输入框") }
                let action = try call("browser_action", ["action": "fill", "tab_id": initial["tab_id"]!, "revision": initial["revision"]!, "ref": field["ref"]!, "value": text])
                _ = try await AgentTools(store: tasks, taskID: id).execute(action)
                _ = try await browser.web.evaluateJavaScript("document.getElementById('flag').checked=true;document.getElementById('choice').value='two';document.getElementById('password').value='PUBLIC_DUMMY_PASSWORD_417';document.cookie='private_task_cookie=first';scrollTo(0,900);document.dispatchEvent(new Event('change',{bubbles:true}));")
                _ = try await browser.open(URL(string: base + "second/form")!, newTab: true)
                _ = try await browser.open(URL(string: base + "post-form")!, newTab: true)
                _ = try await browser.web.evaluateJavaScript("document.getElementById('post').submit();")
                _ = try await browser.read(offset: 1, query: "POST")
                _ = try browser.manageTabs(["action": "switch", "tab_id": firstID])
                openTaskWindow(other, from: control)
                guard let child = additionalTaskWindows.first(where: { $0.agentTaskID == other }) else { throw PetError("独立任务窗口未打开") }
                let otherBrowser = try tasks.browser.show(taskID: other, title: "另一窗口的独立网页"); _ = try await otherBrowser.open(URL(string: base + "other/form")!)
                checks["otherAskTaskUsesIndependentNonpersistentWebsiteData"] = otherBrowser.web.configuration.websiteDataStore !== browser.web.configuration.websiteDataStore && !otherBrowser.web.configuration.websiteDataStore.isPersistent && tasks.task(other)?.workspace == nil
                checks["cookieDoesNotCrossTasks"] = try await otherBrowser.web.evaluateJavaScript("document.cookie") as? String == ""
                control.window?.makeKeyAndOrderFront(nil); control.showAgentTask(id); control.show(tab: "chat")
                guard let addressWindow = control.workspaceSession?.id, let addressTab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == id })?.tabs.first(where: { $0.root == "browser" }) else { throw PetError("浏览器窗口归属不可读") }
                browser.checkWorkspaceAddressSelection(NSRange(location: 0, length: 0))
                guard await flushWorkspaceWindows() else { throw PetError("地址选区前的检查点未保存") }
                browser.checkWorkspaceAddressSelection(NSRange(location: 7, length: 9))
                checks["addressSelectionOnlyChangeAutosavesWithoutExplicitFlush"] = await eventually {
                    guard let page = try? journal.loadPage(windowID: addressWindow, pageID: addressTab.id, taskID: id), let state = try? AgentBrowserRecoveryState.decode(page.saved.value) else { return false }
                    return state.addressSelection == .init(location: 7, length: 9)
                }
                await browser.checkWorkspace("annotate")
                guard let annotation = browser.checkAnnotation else { throw PetError("未添加标注编辑器没有打开") }
                await annotation.checkWorkspace(note: firstNote, mark: true)
                annotation.canvas.kind = .arrow; annotation.canvas.beginMark(at: CGPoint(x: 0.55, y: 0.65)); annotation.canvas.continueMark(at: CGPoint(x: 0.8, y: 0.4)); annotation.canvas.endMark()
                guard await flushWorkspaceWindows(), let window = control.workspaceSession?.id, let otherWindow = child.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == id })?.tabs.first(where: { $0.root == "browser" }) else { throw PetError("浏览器实际检查点未保存") }
                let loaded = try journal.loadPage(windowID: window, pageID: tab.id, taskID: id)!, state = try AgentBrowserRecoveryState.decode(loaded.saved.value)
                checks["threeRealPagesAndSelectedTabPersist"] = state.pages.count == 3 && state.selected == 0 && state.pages[0].url == base + "first/form" && state.pages[2].url == base + "posted"
                checks["realHistoryAndNonzeroScrollPersist"] = browser.pages[0].web.canGoBack && state.pages[0].interaction?.isEmpty == false && abs(state.pages[0].y - 900) < 2
                checks["unsentScreenshotMarksAndNotePersistTogether"] = loaded.saved.value.dirty && state.annotation?.marks.count == 2 && state.annotation?.note == firstNote && state.annotation?.source.tabID == firstID && loaded.asset == nil
                checks["browserAndAnnotationAreBothEligibleForHotExit"] = [ObjectIdentifier(browser), ObjectIdentifier(annotation)].allSatisfy { control.workspaceSession?.preservedEditors.contains($0) == true }
                let pageURL = store.directory.appendingPathComponent("workspace-recovery/" + window + "/pages/" + tab.id + ".json"), original = try Data(contentsOf: pageURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pageURL.path)
                await annotation.checkWorkspace(note: finalNote)
                let rejected = await !flushWorkspaceWindows(), rejectedBytes = try Data(contentsOf: pageURL)
                let failedStatus = await control.taskWorkspaceReadback()["status"] as? String ?? ""
                checks["readOnlyCheckpointFailureRetainsOriginalAndLatestInput"] = rejected && rejectedBytes == original && annotation.workspaceReadback()["note"] as? String == finalNote && control.workspaceSession?.preservedEditors.isEmpty == true && failedStatus.hasPrefix("工作区恢复未保存：")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
                checks["retryPersistsLatestAnnotationWithoutRecreatingIt"] = await flushWorkspaceWindows()
                checks["successfulRetryClearsItsActualVisibleError"] = await control.taskWorkspaceReadback()["status"] as? String == ""
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pageURL.path)
                await annotation.checkWorkspace(note: finalNote + " TEMP")
                let anotherRejection = await !flushWorkspaceWindows()
                control.setStatus("PUBLIC_OTHER_NOTICE_417")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
                let anotherRetry = await flushWorkspaceWindows(), retainedStatus = await control.taskWorkspaceReadback()["status"] as? String
                checks["recoveryRetryDoesNotEraseAnotherStatusMessage"] = anotherRejection && anotherRetry && retainedStatus == "PUBLIC_OTHER_NOTICE_417"
                control.setStatus(""); await annotation.checkWorkspace(note: finalNote, selection: NSRange(location: 0, length: 0))
                guard await flushWorkspaceWindows() else { throw PetError("选区检查前的标注未保存") }
                await annotation.checkWorkspace(selection: NSRange(location: 6, length: 23))
                checks["noteSelectionOnlyChangeAutosavesWithoutExplicitFlush"] = await eventually {
                    guard let page = try? journal.loadPage(windowID: window, pageID: tab.id, taskID: id), let state = try? AgentBrowserRecoveryState.decode(page.saved.value) else { return false }
                    return state.annotation?.selection == .init(location: 6, length: 23)
                }
                fixture = .init(taskID: id, otherID: other, windowID: window, tabID: tab.id, otherWindowID: otherWindow, base: base, imageHash: AgentFiles.hash(state.annotation!.image), note: finalNote, oldAction: action.arguments)
                let saved = try AgentBrowserRecoveryState.decode(load(fixture).saved.value)
                checks["retryKeepsExactCapturedImageAndLatestNote"] = saved.annotation?.note == finalNote && saved.annotation?.image == state.annotation?.image
                var future = saved; future.version = 2
                do { _ = try future.encodedPage(); checks["futureBrowserVersionRejected"] = false } catch { checks["futureBrowserVersionRejected"] = true }
                var wrongOwner = try load(fixture).saved.value; wrongOwner.taskID = other
                do { _ = try AgentBrowserRecoveryState.decode(wrongOwner); checks["wrongOwnerRejectedWithoutMixingTasks"] = false } catch { checks["wrongOwnerRejectedWithoutMixingTasks"] = true }
                let encoded = try JSONEncoder().encode(saved), password = "PUBLIC_DUMMY_PASSWORD_417"
                checks["nativeHistoryDoesNotStoreDummyPasswordPlaintext"] = encoded.range(of: Data(password.utf8)) == nil && saved.pages.allSatisfy { $0.interaction?.range(of: Data(password.utf8)) == nil && $0.interaction?.range(of: password.data(using: .utf16LittleEndian)!) == nil }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(BrowserRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); _ = await flushWorkspaceWindows()
                if stage == "invalid" {
                    let raw = try Data(contentsOf: output.appendingPathComponent("future-browser-input.json"))
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages/" + fixture.tabID + ".json")
                    let retained = try Data(contentsOf: path)
                    checks["unsupportedFutureBrowserStaysColdAndPreservesExactRecord"] = tasks.browser.sessions[fixture.taskID] == nil && control.taskWorkspace.currentController == nil && retained == raw
                    checks["futureBrowserDirtyBadgeIsVisibleWithoutDiscardingDraft"] = (control.taskWorkspace.checkState()["tabLabels"] as? [String] ?? []).contains("• 浏览器")
                } else if stage == "closed" {
                    checks["explicitlyClosedBrowsersDoNotResurrect"] = tasks.browser.sessions.isEmpty && taskControls.allSatisfy { !$0.taskWorkspace.recoveryLayouts.contains(where: { $0.tabs.contains(where: { $0.root == "browser" }) }) }
                    checks["submittedCaptureStaysInOriginalUnsentTask"] = tasks.task(fixture.taskID)?.messages.isEmpty == true && tasks.task(fixture.taskID)?.draft?.contains(fixture.note) == true && tasks.task(fixture.taskID)?.draftAttachmentIDs?.count == 1
                } else {
                    report["restoration"] = ["windowIDs": taskControls.compactMap { $0.workspaceSession?.id }, "browserTasks": Array(tasks.browser.sessions.keys), "mainHasAnnotation": tasks.browser.sessions[fixture.taskID]?.checkAnnotation != nil]
                    guard await flushWorkspaceWindows(), let browser = tasks.browser.sessions[fixture.taskID], let annotation = browser.checkAnnotation,
                          let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.otherWindowID }), let other = tasks.browser.sessions[fixture.otherID] else { throw PetError("两个任务窗口的浏览器或未添加标注没有恢复") }
                    checks["taskWindowIDsAndAnnotationChildRestore"] = control.workspaceSession?.id == fixture.windowID && child.agentTaskID == fixture.otherID && control.taskWorkspace.currentController === annotation
                    let state = try AgentBrowserRecoveryState.decode(load(fixture).saved.value)
                    let restoredAnnotation = try annotation.captureWorkspaceRecovery()
                    checks["capturedImageMarksAndLatestNoteRestoreWithoutRecapture"] = annotation.workspaceReadback()["note"] as? String == fixture.note && annotation.canvas.marks == state.annotation?.marks && AgentFiles.hash(restoredAnnotation.image) == fixture.imageHash
                    checks["noteSelectionRestoresAcrossProcessRestart"] = restoredAnnotation.selection == .init(location: 6, length: 23)
                    let stale = try JSONSerialization.jsonObject(with: Data(fixture.oldAction.utf8)) as! [String: Any]
                    checks["oldTabAndRevisionCannotAuthorizeRestoredPages"] = !browser.pages.contains { $0.id == stale["tab_id"] as? String }
                    do { _ = try await AgentTools(store: tasks, taskID: fixture.taskID).execute(.init(id: "old", name: "browser_action", arguments: fixture.oldAction)); checks["staleToolActionRejectedAfterRestart"] = false } catch { checks["staleToolActionRejectedAfterRestart"] = true }
                    let fresh = try object(await browser.read(offset: 1, query: "网页说明", tabID: browser.pages[0].id))
                    let actual = try await inspect(browser); report["actualRestoredForm"] = actual
                    checks["realFormTextCheckboxAndChoiceRestore"] = actual["note"] as? String == text && actual["checked"] as? Bool == true && actual["choice"] as? String == "two"
                    checks["realScrollAndHistoryRestore"] = abs((actual["y"] as? Double ?? -1) - 900) < 2 && browser.web.canGoBack && browser.pages.count == 3
                    checks["passwordAndCookiesAreNotRestored"] = actual["password"] as? String == "" && actual["cookie"] as? String == ""
                    checks["restoredTaskWebsiteDataRemainsIsolated"] = browser.web.configuration.websiteDataStore !== other.web.configuration.websiteDataStore && !browser.web.configuration.websiteDataStore.isPersistent
                    let history = try object(await browser.act(["action": "back", "tab_id": fresh["tab_id"]!, "revision": fresh["revision"]!]))
                    checks["restoredBackButtonActuallyLoadsPreviousDocument"] = history["url"] as? String == fixture.base + "first/history" && browser.web.canGoForward
                    _ = try await browser.act(["action": "forward", "tab_id": history["tab_id"]!, "revision": history["revision"]!])
                    let returned = try await inspect(browser)
                    checks["restoredForwardButtonKeepsActualFormAndScroll"] = returned["url"] as? String == fixture.base + "first/form" && returned["note"] as? String == text && returned["checked"] as? Bool == true && returned["choice"] as? String == "two" && abs((returned["y"] as? Double ?? -1) - 900) < 2
                    if !interactive {
                        await annotation.checkWorkspace(submit: true)
                        guard await flushWorkspaceWindows(), let attached = tasks.task(fixture.taskID)?.attachments?.last else { throw PetError("恢复的标注没有添加到原任务") }
                        let source = try AgentAttachments.source(store: tasks, taskID: fixture.taskID, id: attached.id)
                        checks["actualRestoredAnnotationAddsOnceToOriginalDraft"] = tasks.task(fixture.taskID)?.draft == "保留主任务输入 PUBLIC_BROWSER_DRAFT_417\n" + fixture.note && tasks.task(fixture.taskID)?.draftAttachmentIDs == [attached.id] && attached.browserCapture?.annotations == 2 && attached.browserCapture?.url == fixture.base + "first/form" && tasks.task(fixture.taskID)?.messages.isEmpty == true
                        checks["attachedImageHashMatchesRealExport"] = try AgentFiles.hash(Data(contentsOf: source)) == attached.sha256
                        checks["successfulAddClearsRecoveryAnnotationAndDirtyState"] = try !load(fixture).saved.value.dirty && AgentBrowserRecoveryState.decode(load(fixture).saved.value).annotation == nil
                        report["attachment"] = ["path": source.path, "sha256": attached.sha256]
                        tasks.browser.close(fixture.taskID); tasks.browser.close(fixture.otherID)
                        checks["explicitCloseRemovesOnlyTheBrowserRoots"] = await flushWorkspaceWindows() && tasks.browser.sessions.isEmpty && tasks.task(fixture.otherID)?.draft == "保留另一窗口输入 PUBLIC_OTHER_618"
                    }
                }
                checks["mainTaskAndOtherTaskDraftsRemainOwned"] = tasks.task(fixture.taskID)?.draft?.hasPrefix("保留主任务输入 PUBLIC_BROWSER_DRAFT_417") == true && tasks.task(fixture.otherID)?.draft == "保留另一窗口输入 PUBLIC_OTHER_618"
            }
            checks["allBrowserMetadataPermissionsArePrivate"] = try FileManager.default.contentsOfDirectory(at: store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.allSatisfy { (try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 }
            checks["noModelsOrFabricatedReplies"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["stage"] = stage
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "browser-recovery-ui-ready.json" : "browser-recovery-report.json"))
    }
}
