import AppKit

@MainActor extension AppDelegate {
    @discardableResult func prepareConversationDisplayUI(_ output: URL, seed: Bool) throws -> [String: String] {
        ensureAgent(); guard let tasks = agentStore else { throw PetError("缺少对话显示验收任务") }
        let file = output.appendingPathComponent("conversation-display-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["completed"], tasks.task(id) != nil else { throw PetError("原对话显示样例不可用") }
            control.showAgentTask(id); control.show(tab: "chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("对话显示样例已存在，请重开原目录") }
        let project = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = "# Public display fixture\n\n本机公开展示样例，不是模型验收输出。\n"
        try Data(readme.utf8).write(to: project.appendingPathComponent("README.md")); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: project.appendingPathComponent("README.md").path)
        let completed = tasks.create(title: "对话显示公开样例", workspace: project.path, mode: .ask)
        let first = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"README.md\"}"), second = AgentToolCall(id: UUID().uuidString, name: "list_directory", arguments: "{\"path\":\".\"}")
        let intermediate = AgentMessage(role: "assistant", content: "唯一中间过程：先核对公开目录。", reasoning: "公开思考样例：先检查文件名，再核对目录。", duration: 1.26, toolCalls: [first, second])
        let final = AgentMessage(role: "assistant", content: "公开样例包含 **README.md**。\n\n这是本机展示样例，未调用模型。", duration: 3.26)
        tasks.update(completed) {
            $0.messages = [AgentMessage(role: "user", content: "查看公开目录。原生展示样例，不调用模型。"), intermediate, AgentMessage(role: "tool", content: readme + String(repeating: "公开响应正文。\n", count: 1800) + "响应末尾-END", toolCallID: first.id), AgentMessage(role: "tool", content: "README.md", toolCallID: second.id), final]
            $0.events = [AgentEvent(kind: "tool", title: "read_file", detail: "事件摘要，完整响应由工具消息提供。", status: "completed", duration: 0.26, toolCallID: first.id), AgentEvent(kind: "tool", title: "list_directory", detail: "README.md", status: "completed", duration: 1.26, toolCallID: second.id)]
            $0.status = .completed; $0.draft = "保留公开任务草稿 🧭"
        }
        let unfinished = tasks.create(title: "未完成过程公开样例", workspace: project.path, mode: .ask)
        tasks.update(unfinished) {
            $0.messages = [AgentMessage(role: "user", content: "未完成的原生展示样例。"), AgentMessage(role: "assistant", content: "未完成的过程不能隐藏。", toolCalls: [first]), AgentMessage(role: "tool", content: "公开失败样例", toolCallID: first.id)]
            $0.events = [AgentEvent(kind: "tool", title: "read_file", detail: "公开失败样例", status: "failed", duration: 1.26, toolCallID: first.id)]; $0.status = .failed; $0.draft = "保留未完成任务草稿"
        }
        let reading = tasks.create(title: "阅读起点公开样例", mode: .ask, workMode: .general)
        tasks.update(reading) {
            $0.messages = (1...18).flatMap { number in [AgentMessage(role: "user", content: "公开历史问题 \(number)"), AgentMessage(role: "assistant", content: "公开历史正文 \(number)\n" + String(repeating: "保留原有阅读内容。\n", count: 3))] }
            $0.draft = "保留阅读任务原输入"
        }
        let ids = ["completed": completed, "unfinished": unfinished, "reading": reading, "reply": final.id, "intermediate": intermediate.id, "firstCall": first.id, "secondCall": second.id, "modelOutputsCreated": "false"]
        try JSONEncoder().encode(ids).write(to: file); control.showAgentTask(completed); control.show(tab: "chat"); return ids
    }
    func conversationDisplayReadingStep(_ step: String, output: URL) throws {
        let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("conversation-display-fixtures.json")))
        guard let id = ids["reading"], let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少阅读样例") }
        if step == "new-round" {
            guard runtime.submit("新一轮公开阅读样例，不启动模型。", taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "公开样例输入未保存") }
        } else if step == "short-reply" {
            tasks.update(id) { $0.status = .running; $0.messages.append(AgentMessage(role: "assistant", content: "公开短回复样例。")) }
        } else if step == "long-reply" {
            tasks.update(id) { record in
                guard let index = record.messages.lastIndex(where: { $0.role == "assistant" }) else { return }
                record.messages[index].content += "\n" + String(repeating: "公开持续增长正文，原输入与历史保持。\n", count: 45); record.status = .ready
            }
        } else { throw PetError("未知的公开阅读步骤") }
        control.renderMessages()
    }
    func runConversationDisplayCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少对话显示验收环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("对话显示验收禁止模型请求") }
            checks["isolatedHomeAndSystemDeliveryBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            let ids = try prepareConversationDisplayUI(output, seed: true), service = generalSettings, file = store.directory.appendingPathComponent("general.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let original = try [ids["completed"]!: encoder.encode(tasks.task(ids["completed"]!)!), ids["unfinished"]!: encoder.encode(tasks.task(ids["unfinished"]!)!)]
            checks["defaultsKeepAllFourSwitchesOffAndIntegerSeconds"] = service.settings.conversationDisplay == .init() && !FileManager.default.fileExists(atPath: file.path)
            var value = service.settings; value.completionNotifications = .never; try service.save(value)
            let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let legacy = output.appendingPathComponent("legacy-display"); try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
            var old = baseline; old.removeValue(forKey: "conversationDisplay"); let oldBytes = try JSONSerialization.data(withJSONObject: old); try oldBytes.write(to: legacy.appendingPathComponent("general.json"))
            let loaded = AgentGeneralSettings(directory: legacy); try loaded.save(loaded.settings)
            checks["tenKeyGeneralConfigurationLoadsDefaultsWithoutRewriting"] = try loaded.error == nil && loaded.settings.conversationDisplay == .init() && Data(contentsOf: legacy.appendingPathComponent("general.json")) == oldBytes
            for (name, bad) in [("null", NSNull() as Any), ("type", "enabled" as Any), ("missing", ["readingStart": false] as Any), ("unknown", ["readingStart": false, "toolCount": false, "expandTools": false, "collapseProcess": false, "durationFormat": "seconds", "other": true] as Any), ("boolean", ["readingStart": "yes", "toolCount": false, "expandTools": false, "collapseProcess": false, "durationFormat": "seconds"] as Any), ("format", ["readingStart": false, "toolCount": false, "expandTools": false, "collapseProcess": false, "durationFormat": "minutes"] as Any)] {
                let path = output.appendingPathComponent("invalid-display-" + name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                var raw = baseline; raw["conversationDisplay"] = bad; let bytes = try JSONSerialization.data(withJSONObject: raw), target = path.appendingPathComponent("general.json"); try bytes.write(to: target)
                let invalid = AgentGeneralSettings(directory: path); var refused = false; do { try invalid.save(.init()) } catch { refused = true }
                checks["invalid-" + name + "-preservesOriginal"] = try refused && invalid.error != nil && Data(contentsOf: target) == bytes
            }
            checks["durationPrecisionUsesRecordedValuesOnly"] = AgentConversationDisplay.DurationFormat.seconds.text(1.26) == "1 秒" && AgentConversationDisplay.DurationFormat.tenths.text(1.26) == "1.3 秒" && AgentConversationDisplay.DurationFormat.seconds.text(nil) == nil && AgentConversationDisplay.DurationFormat.tenths.text(-1) == nil && AgentConversationDisplay.DurationFormat.tenths.text(.infinity) == nil
            let completed = tasks.task(ids["completed"]!)!, unfinished = tasks.task(ids["unfinished"]!)!
            checks["completedProcessUsesActualMessagesAndTwoCallIDs"] = AgentConversationDisplay.processes(completed).map(\.messageIDs) == [[ids["intermediate"]!, ids["reply"]!]] && AgentConversationDisplay.processes(completed).first?.toolCount == 2
            checks["failedProcessCannotBeFoldedAsSuccessfulReply"] = AgentConversationDisplay.processes(unfinished).isEmpty
            var ongoing = completed; ongoing.status = .running; ongoing.messages += [AgentMessage(role: "user", content: "下一轮"), AgentMessage(role: "assistant", content: "尚未完成")]
            checks["newRunningRoundKeepsPriorConfirmedReplyDistinct"] = AgentConversationDisplay.processes(ongoing).map(\.replyID) == [ids["reply"]!]
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func controls(_ owner: ControlWindow) -> [NSControl] { owner.window?.contentView.map(descendants)?.compactMap { $0 as? NSControl }.filter { $0.identifier?.rawValue.hasPrefix("conversation-") == true && !$0.isHiddenOrHasHiddenAncestor } ?? [] }
            func switchValue(_ name: String, _ owner: ControlWindow) throws -> NSSwitch { guard let value = controls(owner).first(where: { $0.identifier?.rawValue == "conversation-" + name }) as? NSSwitch else { throw PetError("缺少对话显示开关：" + name) }; return value }
            guard control.showConversationDisplaySettings(), let window = control.window else { throw PetError("对话显示未进入设置内容页") }
            window.makeKeyAndOrderFront(nil); await wait(0.05)
            checks["settingsChildUsesSameVisibleWindowAndFiveControls"] = control.conversationDisplayReadback()["settingsPageVisible"] as? Bool == true && controls(control).count == 5 && control.conversationDisplayReadback()["heading"] as? String == "对话显示" && window.attachedSheet == nil
            openTaskWindow(ids["completed"]!, from: control); guard let second = additionalTaskWindows.last, second.showConversationDisplaySettings() else { throw PetError("第二个对话显示窗口未打开") }
            for name in ["reading-start", "tool-count", "expand-tools", "collapse-process"] {
                let input = try switchValue(name, control); input.state = .on; _ = input.sendAction(input.action, to: input.target)
                checks[name + "-savesAndSyncsBothWindows"] = try switchValue(name, second).state == .on && AgentGeneralSettings(directory: store.directory).settings == service.settings
            }
            guard let format = controls(control).first(where: { $0.identifier?.rawValue == "conversation-duration-format" }) as? NSPopUpButton else { throw PetError("缺少耗时格式") }
            format.selectItem(at: 1); _ = format.sendAction(format.action, to: format.target)
            checks["durationFormatSavesAndSyncsExistingWindow"] = service.settings.conversationDisplay.durationFormat == .tenths && (controls(second).first(where: { $0.identifier?.rawValue == "conversation-duration-format" }) as? NSPopUpButton)?.selectedItem?.title == "一位小数"
            let saved = try Data(contentsOf: file); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            let expanded = try switchValue("expand-tools", control); expanded.state = .off; _ = expanded.sendAction(expanded.action, to: expanded.target)
            checks["readOnlySaveRollsBackVisibleNestedControlsAndBytes"] = try expanded.state == .on && switchValue("expand-tools", second).state == .on && Data(contentsOf: file) == saved
            for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                window.makeKeyAndOrderFront(nil); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                checks[name + "-fiveControlsFitWithoutAmbiguousLayout"] = controls(control).count == 5 && controls(control).allSatisfy { !$0.hasAmbiguousLayout && $0.bounds.width >= 20 } && window.contentView?.bounds.size == size
                checks[name + "-saveFailureRemainsVisible"] = descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.accessibilityLabel() == "常规设置保存状态" && $0.stringValue.contains("只读") && !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.height >= $0.bounds.height - 1 }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            window.setContentSize(NSSize(width: 1200, height: 774)); control.show(tab: "chat"); control.renderMessages()
            var state = control.conversationDisplayReadback(), tools = state["tools"] as! [String: [String: Any]], processes = state["processes"] as! [String: [String: Any]]
            checks["completedReplyStaysVisibleWhileItsRealProcessIsFolded"] = (state["messages"] as? [String: [String: Any]])?[ids["reply"]!]?["visible"] as? Bool == true && processes[ids["reply"]!]?["expanded"] as? Bool == false
            checks["foldedCaptionShowsActualToolCallCount"] = (processes[ids["reply"]!]?["caption"] as? String)?.contains("2 次工具调用") == true
            checks["toolDefaultsAndCompleteResponseUsePersistedData"] = tools[ids["firstCall"]!]?["expanded"] as? Bool == true && (tools[ids["firstCall"]!]?["detail"] as? String)?.hasSuffix("响应末尾-END") == true && (tools[ids["firstCall"]!]?["detail"] as? String)?.contains("\"path\" : \"README.md\"") == true
            checks["toolAndReplyDurationUseSelectedPrecision"] = (tools[ids["firstCall"]!]?["title"] as? String)?.contains("0.3 秒") == true && (state["messages"] as? [String: [String: Any]])?[ids["reply"]!]?["duration"] as? String == "耗时 3.3 秒"
            control.checkConversationDisplay("expandProcess", id: ids["reply"]!); control.checkConversationDisplay("collapseTool", id: ids["firstCall"]!); control.renderMessages()
            tools = control.conversationDisplayReadback()["tools"] as! [String: [String: Any]]
            checks["manualToolChoiceSurvivesStreamingRefresh"] = tools[ids["firstCall"]!]?["expanded"] as? Bool == false
            control.showAgentTask(ids["completed"]!); control.checkConversationDisplay("search", id: ids["intermediate"]!, query: "唯一中间过程"); state = control.conversationDisplayReadback()
            checks["searchRevealsOriginalTextInsideFoldedProcess"] = ((state["processes"] as? [String: [String: Any]])?[ids["reply"]!]?["expanded"] as? Bool) == true && ((state["messages"] as? [String: [String: Any]])?[ids["intermediate"]!]?["visible"] as? Bool) == true
            control.showAgentTask(ids["unfinished"]!); state = control.conversationDisplayReadback()
            checks["failedTaskKeepsProcessAndToolVisible"] = (state["processes"] as? [String: [String: Any]])?.isEmpty == true && (state["tools"] as? [String: [String: Any]])?[ids["firstCall"]!]?["detailVisible"] as? Bool == true
            checks["settingsAndDisplayLeaveOriginalRecordsExact"] = try original.allSatisfy { try encoder.encode(tasks.task($0.key)!) == $0.value }
            control.showAgentTask(ids["reading"]!); control.renderMessages()
            try conversationDisplayReadingStep("new-round", output: output); await wait(0.05); control.renderMessages(); state = control.conversationDisplayReadback()
            let anchor = state["readingAnchor"] as? String ?? "", viewport = NSRectFromString(state["viewport"] as? String ?? ""), row = (state["messages"] as? [String: [String: Any]])?[anchor]
            checks["newHumanRoundStartsAtViewportTopWithSpace"] = !anchor.isEmpty && (state["readingSpace"] as? Double ?? 0) > 100 && abs(NSRectFromString(row?["frame"] as? String ?? "").minY - viewport.minY) < 1
            try conversationDisplayReadingStep("short-reply", output: output); state = control.conversationDisplayReadback()
            checks["shortGrowingReplyKeepsSameReadingStart"] = state["readingAnchor"] as? String == anchor && (state["readingSpace"] as? Double ?? 0) > 0
            try conversationDisplayReadingStep("long-reply", output: output); await wait(0.05); control.renderMessages(); state = control.conversationDisplayReadback()
            checks["filledViewportReturnsToFollowingActualBottom"] = state["readingAnchor"] as? String == "" && (state["readingSpace"] as? Double) == 0 && abs(NSRectFromString(state["viewport"] as? String ?? "").maxY - (state["documentHeight"] as? Double ?? 0)) < 1
            try conversationDisplayReadingStep("new-round", output: output); control.checkConversationDisplay("cancelReading"); state = control.conversationDisplayReadback()
            checks["manualScrollCancelsReadingAnchorAndSpace"] = state["readingAnchor"] as? String == "" && (state["readingSpace"] as? Double) == 0
            report["finalState"] = state; second.window?.orderOut(nil)
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = attempts; report["modelRequests"] = agentStore?.tasks.reduce(0) { $0 + ($1.modelReceipts?.count ?? 0) } ?? 0
        report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["success"] = report["error"] == nil && checks.values.allSatisfy { $0 } && !checks.isEmpty && attempts == 0
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("conversation-display-report.json"))
        print("conversation display: \(checks.filter { $0.value }.count)/\(checks.count)")
    }
}
