import AppKit

@MainActor extension AppDelegate {
    func runAgentAppShotCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], attempts = 0
        let binary = Bundle.main.executableURL!, hash = (try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)) ?? ""
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            try write(["appPID": getpid(), "binaryHash": hash], "appshot-started.json")
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("AppShot 原生验收不调用模型") }
            let workspace = output.appendingPathComponent("workspace"), source = try String(contentsOf: workspace.appendingPathComponent("README.md"), encoding: .utf8)
            let original = "本轮只核对实际窗口快照，不发送模型。\n" + source.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
            let id = tasks.create(workspace: workspace.path, mode: .ask); tasks.update(id) { $0.draft = original }; control.showAgentTask(id); control.show(tab: "chat")
            let deadline = Date().addingTimeInterval(3)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), Date() < deadline { await wait(0.05) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), let window = control.window else { throw PetError("候选应用未在前台，未截取其他应用") }
            checks["globalShortcutInitiallyDisabled"] = appShot.shortcut == .disabled
            let beforePermissions = tasks.desktop.status
            let shot = try await AgentAppShotCapture.frontmost(expectedApplication: NSRunningApplication.current, expectedOwnWindow: window.windowNumber)
            checks["actualOwnWindowIdentityAndImage"] = shot.source.windowID == CGWindowID(window.windowNumber) && shot.source.bundleID == Bundle.main.bundleIdentifier && !shot.data.isEmpty && ["own-window", "own-software"].contains(shot.source.method ?? "")
            checks["actualAccessibleComposerText"] = shot.text.contains("本轮只核对实际窗口快照") && shot.text.contains("小鲸") && shot.source.textHash == AgentFiles.hash(Data(shot.text.utf8))
            let privateWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false), secure = NSSecureTextField(string: "受保护的原生检查输入")
            let panel = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120)), hidden = NSTextField(labelWithString: "隐藏区域的原生检查内容")
            secure.frame = NSRect(x: 10, y: 60, width: 260, height: 24); hidden.frame = NSRect(x: 10, y: 20, width: 260, height: 24); hidden.isHidden = true
            panel.addSubview(secure); panel.addSubview(hidden); privateWindow.contentView = panel
            privateWindow.isReleasedWhenClosed = false
            privateWindow.orderFront(nil)
            let protectedText = AgentAppShotCapture.ownText(privateWindow).0
            checks["nativeSecureFieldValueExcluded"] = !protectedText.contains("受保护的原生检查输入") && protectedText.contains("[受保护输入]")
            checks["nativeHiddenViewTextExcluded"] = !protectedText.contains("隐藏区域的原生检查内容")
            privateWindow.close()
            checks["invalidUTF8BoundaryNeverProduced"] = AgentAppShotCapture.prefix("界面快照", bytes: 4) == "界"
            try shot.data.write(to: output.appendingPathComponent("actual-window.png"))
            let file = try await control.attachAppShot(shot, taskID: id)
            checks["savedAsUnsentActualImageAndText"] = tasks.task(id)?.draftAttachmentIDs == [file.id] && tasks.task(id)?.messages.isEmpty == true && file.desktopCapture?.appShot == true && file.sha256 == AgentFiles.hash(shot.data)
            let content = try AgentAttachments.content(store: tasks, taskID: id, id: file.id)
            checks["fullAccessibleTextRetainedExactly"] = content.parts.count == 1 && content.parts[0].text == shot.text && content.parts[0].ocr != true
            checks["unsentDraftExcludedFromModelContext"] = tasks.task(id)?.availableAttachmentIDs.isEmpty == true && AgentAppShotCapture.contexts(tasks.task(id)!, maximum: 1).isEmpty && AgentAttachmentVisuals.references(tasks.task(id)!.messages).isEmpty
            let tools = AgentTools(store: tasks, taskID: id)
            do { _ = try await tools.execute(AgentToolCall(id: "appshot-unsent", name: "read_attachment", arguments: "{\"id\":\"" + file.id + "\"}")); checks["unsentAttachmentToolReadRejected"] = false }
            catch { checks["unsentAttachmentToolReadRejected"] = error.localizedDescription.contains("只能读取当前任务已发送的附件") }
            let another = tasks.create(workspace: nil, mode: .ask); tasks.update(another) { $0.draft = "另一个任务的未发送草稿" }; control.showAgentTask(another)
            checks["switchingTasksKeepsSnapshotOwner"] = tasks.task(id)?.draftAttachmentIDs == [file.id] && tasks.task(another)?.attachments?.isEmpty != false && tasks.task(another)?.draft == "另一个任务的未发送草稿"
            control.showAgentTask(id)
            guard runtime.submit("请按我提交的窗口快照核对可读文字。", taskID: id, attachmentIDs: [file.id], startImmediately: false), let submitted = tasks.task(id) else { throw PetError("窗口快照未能按正常输入流程提交") }
            checks["submissionKeepsUserOriginalAndImageReference"] = submitted.messages.last?.isHumanInput == true && submitted.messages.last?.content == "请按我提交的窗口快照核对可读文字。" && submitted.messages.last?.visuals == [.init(id: file.id, part: 1)] && submitted.messages.last?.visualsDelivered == false
            let context = AgentContext.window(submitted, maximumImages: 1)
            checks["onlySubmittedSnapshotAddsActualTextContext"] = context.contains { $0.nativeContext == true && $0.content.contains("本轮只核对实际窗口快照") } && submitted.availableAttachmentIDs.contains(file.id)
            var preferences = PetPreferences(); preferences.visionMode = "on"
            let inputs = try await AgentAttachmentVisuals.prepare(messages: context, store: tasks, taskID: id, preferences: preferences)
            checks["actualImagePreparedWithoutTransmission"] = inputs.values.flatMap { $0 }.count == 1 && (inputs.values.flatMap { $0 }.first?.image.width ?? 0) > 100
            let wire = AgentAttachmentVisuals.wire(messages: context, inputs: inputs), data = try JSONSerialization.data(withJSONObject: wire)
            checks["actualPNGAndTextReachRequestPayloadOnlyAfterSubmit"] = String(decoding: data, as: UTF8.self).contains("data:image/jpeg;base64,") && String(decoding: data, as: UTF8.self).contains("本轮只核对实际窗口快照")
            try appShot.setShortcut(.command)
            checks["localShortcutConfigPersistedWithoutExternalMonitor"] = appShot.shortcut == .command && appShot.checkState()["globalMonitor"] as? Bool == false
            appShot.reload(); checks["shortcutReopens"] = appShot.shortcut == .command
            try appShot.setShortcut(.disabled)
            checks["disableRemovesMonitors"] = appShot.checkState()["localMonitor"] as? Bool == false && appShot.checkState()["globalMonitor"] as? Bool == false
            checks["systemPermissionsUnchanged"] = beforePermissions["accessibility"] as? Bool == tasks.desktop.status["accessibility"] as? Bool && beforePermissions["screen_recording"] as? Bool == tasks.desktop.status["screen_recording"] as? Bool
            checks["noModelAttemptAssistantReceiptOrJob"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty && !runtime.isRunning($0.id) }
            let metadata = try JSONEncoder().encode(file)
            try metadata.write(to: output.appendingPathComponent("actual-attachment.json"))
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "taskID": id, "otherTaskID": another, "attachmentID": file.id, "sourceHash": AgentFiles.hash(Data(source.utf8)), "blockedModelAttempts": attempts, "success": checks.values.allSatisfy { $0 }], "appshot-result.json")
        } catch { try? write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": attempts, "success": false, "error": error.localizedDescription], "appshot-result.json") }
    }
}
