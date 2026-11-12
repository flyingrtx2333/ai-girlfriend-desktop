import AppKit

@MainActor extension AppDelegate {
    func prepareOperationConfirmationUI(_ output: URL, seed: Bool) async throws {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui") else { throw PetError("操作确认验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务系统不可用") }
        if seed {
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks)
            guard let project = tasks.task(id)?.workspace else { throw PetError("缺少确认验收项目") }
            tasks.update(id) { $0.draft = "保留操作确认验收输入"; $0.artifacts = [URL(fileURLWithPath: project).appendingPathComponent("README.md").path] }
        }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("settings-fixtures.json"))) as? [String: Any]
        guard let id = fixture?["taskID"] as? String, tasks.task(id) != nil else { throw PetError("未找到原操作确认验收资料") }
        control.showAgentTask(id)
    }
    func runOperationConfirmationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], dialogs: [[String: Any]] = [], requests = 0
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false), pane = AgentSettingsPageHost()
        host.contentView = pane; host.isReleasedWhenClosed = false
        var comparison: AgentFileConflictWindow?
        defer { comparison?.close(); pane.finish(); host.close(); agentRuntime?.stopAll() }
        func find<T: NSView>(_ type: T.Type, _ root: NSView?, matching predicate: (T) -> Bool) -> T? {
            guard let root else { return nil }; if let value = root as? T, predicate(value) { return value }
            for child in root.subviews { if let value = find(type, child, matching: predicate) { return value } }; return nil
        }
        func button(_ title: String, _ root: NSView?) throws -> NSButton {
            guard let value = find(NSButton.self, root, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少确认验收操作：" + title) }; return value
        }
        func probe(_ choice: String, owner: NSWindow, _ action: () async throws -> Void) async throws {
            var clicked = false, expired = false
            let limit = Date().addingTimeInterval(8)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard !clicked else { return }
                    if let window = NSApp.modalWindow ?? owner.attachedSheet, let selected = find(NSButton.self, window.contentView, matching: { $0.title == choice }) {
                        clicked = true; var text: [String] = [], titles: [String] = [], destructive: [String] = []
                        func collect(_ view: NSView) {
                            if let button = view as? NSButton { if !button.title.isEmpty { titles.append(button.title); if button.hasDestructiveAction { destructive.append(button.title) } } }
                            else if let field = view as? NSTextField { text.append(field.stringValue) }
                            else if let editor = view as? NSTextView { text.append(editor.string) }
                            view.subviews.forEach(collect)
                        }
                        if let root = window.contentView { collect(root) }
                        dialogs.append(["choice": choice, "sheet": window.sheetParent === owner, "modal": NSApp.modalWindow === window, "buttons": titles, "destructiveButtons": destructive, "text": text.joined(separator: "\n"), "styled": window.contentView is AgentThemeView, "default": window.defaultButtonCell?.title ?? "", "width": window.frame.width, "height": window.frame.height])
                        selected.performClick(nil)
                    } else if Date() >= limit { expired = true; timer.invalidate(); NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            try await action()
            while (!clicked || owner.attachedSheet != nil), !expired, Date() < limit { await wait(0.02) }
            guard clicked, !expired, owner.attachedSheet == nil else { throw PetError("操作确认未完成：" + choice) }
        }
        func show(_ page: AgentSettingsPageController, _ key: String) throws {
            guard pane.show(category: key, identity: key, scope: "操作确认验收", make: { _ in page }) else { throw PetError("无法进入操作确认验收页") }; host.makeKeyAndOrderFront(nil)
        }
        do {
            try await prepareOperationConfirmationUI(output, seed: true)
            guard let tasks = agentStore, let runtime = agentRuntime, let id = tasks.selectedID, let workspace = tasks.task(id)?.workspace else { throw PetError("缺少操作确认验收任务") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("操作确认验收禁止模型请求") }
            checks["isolatedProfileAndBlockedModelTransmission"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            let config = tasks.extensions.profile.appendingPathComponent("extensions/mcp.json"), configBytes = try Data(contentsOf: config), serverIDs = tasks.mcp.availableServers(workspace: workspace).map(\.id)
            let mcp = AgentMCPWindow(service: tasks.mcp, workspace: workspace); try show(mcp, "mcp")
            try await probe("取消", owner: host) { try button("移除", mcp.pageContentView).performClick(nil) }
            checks["synchronousRemoveCancelPreservesActualMCPConfiguration"] = try Data(contentsOf: config) == configBytes && tasks.mcp.availableServers(workspace: workspace).map(\.id) == serverIDs
            guard pane.leave() else { throw PetError("连接器确认未能结束") }
            let rules = AgentRuleWindow(store: tasks, taskID: id); try show(rules, "rules")
            let ruleFiles = try tasks.rules.catalog(workspace: workspace).map(\.source), ruleBytes = try ruleFiles.map { try Data(contentsOf: $0) }
            try await probe("取消", owner: host) { try button("移到废纸篓", rules.pageContentView).performClick(nil) }
            checks["asynchronousSheetCancelPreservesRuleFilesAndReleasesOwner"] = try ruleFiles.enumerated().allSatisfy { try Data(contentsOf: $0.element) == ruleBytes[$0.offset] } && host.attachedSheet == nil && dialogs.last?["sheet"] as? Bool == true && dialogs.last?["modal"] as? Bool == false
            guard pane.leave() else { throw PetError("规则确认未能结束") }
            let desktop = AgentDesktopSettingsView(desktop: tasks.desktop), beforeDesktop = try tasks.desktop.configuration()
            host.contentView = desktop; host.makeKeyAndOrderFront(nil)
            guard let toggle = find(NSSwitch.self, desktop, matching: { _ in true }), let action = toggle.action else { throw PetError("缺少电脑操作开关") }
            try await probe("取消", owner: host) { toggle.state = .on; NSApp.sendAction(action, to: toggle.target, from: toggle) }
            let afterDesktop = try tasks.desktop.configuration()
            checks["enableCancelDoesNotGrantComputerAccess"] = !beforeDesktop.enabled && !afterDesktop.enabled && beforeDesktop.hash == afterDesktop.hash && toggle.state == .off
            host.contentView = pane
            let file = URL(fileURLWithPath: workspace).appendingPathComponent("README.md"), original = try Data(contentsOf: file), draft = "# 保留覆盖确认草稿\n", snapshot = try AgentFileConflictSnapshot.read(file: file, workspace: workspace, draft: draft, allowsOverwrite: true)
            var resolutions = 0
            let fileWindow = AgentFileConflictWindow(file: file, protectedData: tasks.directory, read: { snapshot }, resolve: { _, _ in resolutions += 1 }); comparison = fileWindow
            fileWindow.showWindow(nil); fileWindow.window?.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(20)
            while (try? button("覆盖文件…", fileWindow.pageContentView)) == nil, Date() < deadline { await wait(0.05) }
            guard let fileHost = fileWindow.window else { throw PetError("缺少文件比较窗口") }
            try await probe("取消", owner: fileHost) { try button("覆盖文件…", fileWindow.pageContentView).performClick(nil) }
            checks["overwriteCancelDoesNotInvokeResolutionOrChangeDiskAndDraft"] = try resolutions == 0 && Data(contentsOf: file) == original && snapshot.draft == Data(draft.utf8)
            fileWindow.close(); comparison = nil
            var temporaryIDs: [String] = []
            for index in 1...25 { temporaryIDs.append(tasks.create(title: "取消删除验收-\(index)", workspace: workspace)) }
            control.showAgentTask(id); control.show(tab: "chat")
            let stored = try Dictionary(uniqueKeysWithValues: temporaryIDs.map { ($0, try Data(contentsOf: tasks.directory.appendingPathComponent($0 + ".json"))) })
            try await probe("取消", owner: control.window!) { _ = try await control.checkOperationDeletion(temporaryIDs) }
            checks["permanentDeleteCancelRetainsAll25ActualRecords"] = try temporaryIDs.allSatisfy { try tasks.task($0) != nil && Data(contentsOf: tasks.directory.appendingPathComponent($0 + ".json")) == stored[$0] }
            let deletionLines = Set((dialogs.last?["text"] as? String ?? "").components(separatedBy: .newlines))
            report["allDeletionNamesPresented"] = (1...25).allSatisfy { deletionLines.contains("取消删除验收-\($0)") }
            var callbacks = 0, response = NSApplication.ModalResponse.abort
            host.makeKeyAndOrderFront(nil)
            try await probe("允许", owner: host) {
                let alert = AgentConfirmation(); alert.messageText = "公开回调验收"; alert.addButton(withTitle: "允许"); alert.addButton(withTitle: "取消")
                alert.beginSheetModal(for: host) { callbacks += 1; response = $0 }
            }
            let callbackDeadline = Date().addingTimeInterval(2)
            while callbacks == 0, Date() < callbackDeadline { await wait(0.02) }
            checks["sheetApprovalDeliversOriginalResponseExactlyOnce"] = callbacks == 1 && response == .alertFirstButtonReturn && host.attachedSheet == nil
            checks["noModelRequestsAndOriginalConversationDraftRetained"] = requests == 0 && tasks.task(id)?.draft == "保留操作确认验收输入" && tasks.tasks.allSatisfy { $0.inputTokens == 0 && $0.outputTokens == 0 && $0.modelReceipts?.isEmpty != false }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["dialogs"] = dialogs; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("operation-confirmation-report.json"))
    }
}
