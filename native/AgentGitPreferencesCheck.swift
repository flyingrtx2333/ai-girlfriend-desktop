import AppKit

@MainActor extension AppDelegate {
    func runGitPreferencesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelRequests": 0]
        do { try await checkGitPreferences(output, checks: &checks, report: &report) }
        catch { report["error"] = error.localizedDescription }
        report["checks"] = checks
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("git-preferences-report.json"), options: .atomic)
    }

    private func checkGitPreferences(_ output: URL, checks: inout [String: Bool], report: inout [String: Any]) async throws {
        ensureAgent()
        guard let tasks = agentStore, let runtime = agentRuntime, let window = control.window else { throw PetError("任务窗口不可用") }
        let settings = tasks.gitPreferences
        let defaults = try settings.read()
        checks["missingPreferencesUseExistingPrefix"] = defaults.revision == nil && defaults.values == .init()
        guard control.checkWorktreeSettingsPage() != nil else { throw PetError("工作树设置页未打开") }
        let empty = await control.taskWorkspaceReadback()["settingsWorktrees"] as? [String: Any]
        checks["emptyWorktreesHideUnavailableControls"] = empty?["emptyProjectsVisible"] as? Bool == true
            && empty?["projectPickerVisible"] as? Bool == false && empty?["historyVisible"] as? Bool == false

        guard control.showSettingsCategory("git"), let content = window.contentView else { throw PetError("Git 设置页未打开") }
        func views(_ root: NSView) -> [NSView] {
            root.isHidden ? [] : [root] + root.subviews.flatMap(views)
        }
        await wait(0.2)
        let visible = views(content)
        guard let prefix = visible.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "分支前缀" }),
              let instructions = visible.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "提交说明指令" }),
              let save = visible.compactMap({ $0 as? NSButton }).first(where: { $0.title == "保存" }) else { throw PetError("Git 设置控件不可用") }
        checks["defaultVisibleWithoutSave"] = prefix.stringValue == "agent/" && instructions.string.isEmpty && !save.isEnabled
        func editPrefix(_ value: String) {
            window.makeFirstResponder(nil)
            prefix.stringValue = value
            prefix.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: prefix))
        }
        let directive = "PUBLIC_SUBJECT_RULE\n使用 fix: 开头"
        editPrefix("bad prefix/")
        if save.isEnabled { save.performClick(nil) }
        checks["invalidPrefixLeavesSavedPreferencesUntouched"] = try settings.read().revision == nil && save.isEnabled
        editPrefix("release/")
        instructions.string = directive
        instructions.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: instructions))
        let recovery = try control.captureSettingsRecovery()
        checks["unsavedSettingsHaveRecoveryState"] = recovery?.category == "git" && recovery?.pages.first?.kind == "git"
        if save.isEnabled { save.performClick(nil) }
        let saved = try settings.read()
        let mode = (try FileManager.default.attributesOfItem(atPath: settings.profile.appendingPathComponent("git-preferences.json").path))[.posixPermissions] as? Int
        checks["normalSavePersistsBothFieldsPrivately"] = saved.values == .init(branchPrefix: "release/", commitInstructions: directive)
            && saved.revision != nil && mode == 0o600 && !save.isEnabled
        do { _ = try settings.save(.init(), replacing: defaults.revision); checks["staleSettingsCannotReplaceSavedValues"] = false }
        catch { checks["staleSettingsCannotReplaceSavedValues"] = try settings.read().revision == saved.revision }

        let server = output.appendingPathComponent("git-subject-fixture.mjs")
        let portFile = output.appendingPathComponent("git-subject-port.txt")
        let requestFile = output.appendingPathComponent("git-subject-request.json")
        let subject = "fix: 更新公开文件"
        let fixture = #"""
        import fs from 'node:fs';
        import http from 'node:http';
        const server = http.createServer(async (request, response) => {
          if (request.url !== '/v1/chat/completions' || request.method !== 'POST') {
            response.writeHead(404); response.end(); return;
          }
          const chunks = [];
          for await (const chunk of request) chunks.push(chunk);
          fs.writeFileSync(process.argv[3], Buffer.concat(chunks), {flag: 'wx'});
          response.writeHead(200, {'Content-Type': 'application/json'});
          response.end(JSON.stringify({model: 'fixture-loopback', choices: [{message: {content: process.argv[4]}, finish_reason: 'stop'}], usage: {prompt_tokens: 55, completion_tokens: 8}}));
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(server.address().port)));
        """#
        try Data(fixture.utf8).write(to: server)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        process.arguments = [server.path, portFile.path, requestFile.path, subject]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning, Date() < deadline { await wait(0.025) }
        guard let port = Int(try String(contentsOf: portFile, encoding: .utf8)), (1...65_535).contains(port) else { throw PetError("本机模型样例未启动") }
        let endpoint = "http://127.0.0.1:\(port)/v1"
        store.preferences.endpoint = endpoint; store.preferences.model = "fixture-loopback"
        store.preferences.contextTokens = 8192; store.preferences.replyTokens = 512
        try store.keychain.write("LOCAL-FIXTURE-ONLY", account: "chat")
        let id = try await prepareWorkspaceWorktreeFixtures(output, tasks: tasks)
        var admissions = 0
        runtime.modelRequestCheck = {
            guard admissions == 0, try runtime.taskPreferences(id).endpoint == endpoint else { throw PetError("只允许一次本机样例请求") }
            admissions += 1
        }
        defer { runtime.modelRequestCheck = { throw PetError("本机样例已结束") } }
        control.show(tab: "chat"); control.showAgentTask(id); control.createTaskWorktree()
        guard let worktree = control.taskWorkspace.currentController as? AgentWorktreeCreationWindow else { throw PetError("工作树创建页未打开") }
        await worktree.checkWorkspace()
        let defaultBranch = worktree.workspaceReadback()["branch"] as? String ?? ""
        checks["newWorktreeUsesSavedBranchPrefix"] = defaultBranch.range(of: #"^release/[0-9a-f]{8}$"#, options: .regularExpression) != nil
        control.taskWorkspace.checkBack()
        guard let review = control.taskWorkspace.currentController as? AgentGitWindow, let task = tasks.task(id), let workspace = task.workspace else { throw PetError("Git 审阅未打开") }
        let repository = URL(fileURLWithPath: workspace)
        let index = repository.appendingPathComponent(".git/index"), file = repository.appendingPathComponent("public.txt")
        let before = try Data(contentsOf: index), bytes = try Data(contentsOf: file)
        let head = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: repository, output: output)
        await review.checkWorkspace(source: .staged, path: "public.txt", action: "generate")
        report["loopbackRequests"] = admissions
        let generated = review.workspaceReadback()
        report["generationState"] = generated["state"]
        checks["explicitActionPopulatesDraft"] = generated["draft"] as? String == subject && generated["state"] as? String == "已生成提交说明"
        guard FileManager.default.fileExists(atPath: requestFile.path) else { throw PetError("生成说明未发出本机样例请求") }
        let request = try AgentConfigurationJSON.object(Data(contentsOf: requestFile))
        let messages = request["messages"] as? [[String: Any]] ?? []
        let message = messages.first(where: { $0["role"] as? String == "user" })?["content"] as? String ?? ""
        checks["requestUsesInstructionsAndSelectedIndexDiffOnly"] = admissions == 1 && messages.count == 2 && message.contains(directive)
            && message.contains("+staged-1") && !message.contains("working-1") && !message.contains("staged-0") && !message.contains("保留多源工作树原草稿")
        checks["requestUsesConfiguredModelAndNoTools"] = request["model"] as? String == "fixture-loopback"
            && request["max_tokens"] as? Int == 512 && (request["tools"] as? [Any] ?? []).isEmpty
        let afterHead = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: repository, output: output)
        checks["generationDoesNotChangeGitOrConversation"] = try afterHead == head && Data(contentsOf: index) == before
            && Data(contentsOf: file) == bytes && tasks.task(id)?.messages.isEmpty == true && tasks.task(id)?.draft == task.draft
        checks["generatedDraftIsRecoverable"] = try review.captureWorkspaceRecovery(persistClean: false) != nil
        await review.checkWorkspace(action: "generate")
        checks["generationDoesNotOverwriteDraft"] = admissions == 1 && review.workspaceReadback()["draft"] as? String == subject
        await review.checkWorkspace(message: "")

        var withoutPrefix = saved.values; withoutPrefix.branchPrefix = ""
        _ = try settings.save(withoutPrefix, replacing: saved.revision)
        checks["emptyPrefixIsAcceptedAndAddsNothing"] = settings.suggestedBranch().range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }
}
