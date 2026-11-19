import AppKit

@MainActor extension AppDelegate {
    func runInlineHookImportCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], errorText: String?
        do { try await checkInlineHookImport(output, checks: &checks) }
        catch { errorText = error.localizedDescription }
        var report: [String: Any] = ["success": errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
                                     "checks": checks, "modelRequests": 0, "appPID": getpid()]
        report["error"] = errorText
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("inline-hook-import-report.json"), options: .atomic)
    }

    private func checkInlineHookImport(_ output: URL, checks: inout [String: Bool]) async throws {
        let fm = FileManager.default, profile = output.appendingPathComponent("profile"), shared = output.appendingPathComponent("shared-home")
        let incoming = output.appendingPathComponent("Codex Project"), offline = output.appendingPathComponent("Codex Project Offline")
        let project = output.appendingPathComponent("Harbor"), other = output.appendingPathComponent("Other"), user = shared.appendingPathComponent(".codex")
        let originalTitle = "PUBLIC HARBOR HOOK 5739 and long verified context"
        let privateMarker = "SYNTHETIC-CONFIG-MARKER-580413"
        let projectTOML = """
        model = "fixture-model"
        [mcp_servers.ignored.env]
        PRIVATE_SETTING = "\(privateMarker)"

        [[hooks.SessionStart]]
        matcher = "^startup$"
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = '/bin/sh "$(git rev-parse --show-toplevel)/.codex/hooks/start review.sh"'
        additionalContextLimit = 8
        statusMessage = "核对项目报告"

        [[hooks.PreToolUse]]
        matcher = "^apply_patch$"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "/usr/bin/true"
        command_windows = "\(privateMarker)"
        timeout = 12

        [[hooks.PreModelRequest]]
        hooks = [{ type = "command", command = "/usr/bin/true" }]

        [[hooks.Interrupt]]
        hooks = [{ type = "command", command = "/usr/bin/true" }]

        [[hooks.FutureObserver]]
        hooks = [{ type = "command", command = "/usr/bin/true" }]

        [[hooks.PostToolUse]]
        hooks = [{ type = "mcp_tool", server = "elsewhere", tool = "fixture", input = { api_key = "\(privateMarker)" } }]

        [hooks.state."old-approval"]
        enabled = true
        trusted_hash = "\(privateMarker)"
        """
        let projectScript = #"""
        #!/bin/sh
        IFS= read -r input
        case "$input" in *'"hook_event_name":"SessionStart"'*) ;; *) exit 4 ;; esac
        IFS= read -r title < README.md || exit 5
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$title"
        """#
        let userScript = #"""
        #!/bin/sh
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"PUBLIC USER HOOK 4781"}}'
        """#
        let userTOML = #"""
        hooks.SessionStart = [{ hooks = [{ type = "command", command = '/bin/sh "$HOME/.codex/hooks/user-check.sh"' }] }]
        """#
        let file = incoming.appendingPathComponent(".codex/config.toml"), script = incoming.appendingPathComponent(".codex/hooks/start review.sh")
        let json = incoming.appendingPathComponent(".codex/hooks.json")

        func write(_ text: String, to file: URL, mode: Int = 0o640) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((text + "\n").utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        func waitForImport(_ importer: AgentDataImport) async throws {
            let deadline = Date().addingTimeInterval(15)
            while importer.active && Date() < deadline { await wait(0.025) }
            guard !importer.active else { throw PetError("Hooks 批次未结束") }
        }
        func record(_ importer: AgentDataImport, _ filename: String) throws -> AgentImportCandidate {
            guard let item = importer.preview.first(where: { $0.title == filename }) else { throw PetError("缺少导入预览 " + filename) }
            return item
        }
        func newStore() -> AgentStore { AgentStore(directory: profile, legacy: [], extensionHome: shared) }

        try write(originalTitle, to: project.appendingPathComponent("README.md"))
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try write(projectTOML, to: file)
        try write(projectScript, to: script, mode: 0o751)
        try write(#"{"hooks":{"Stop":[{"hooks":[{"name":"公开 JSON 命令","type":"command","command":"/usr/bin/true"}]}]}}"#, to: json)
        try write(userTOML, to: user.appendingPathComponent("config.toml"))
        try write(userScript, to: user.appendingPathComponent("hooks/user-check.sh"), mode: 0o751)
        let original = [file, json, user.appendingPathComponent("config.toml")]
        let inputBytes = try original.map { try Data(contentsOf: $0) }
        let store = newStore(), importer = store.dataImport
        try store.organization.register(project.path, mode: .coding)
        try store.organization.register(other.path, mode: .coding)
        let grants = profile.appendingPathComponent("extensions/hook-settings.json")

        await importer.detect(.codex, root: incoming, category: .configuration)
        checks["projectConfigAndJSONRequireDestination"] = importer.preview.count == 3
            && importer.preview.allSatisfy { $0.issue?.contains("选择目标项目") == true }
        await importer.detect(.codex, root: incoming, category: .configuration, workspace: project.path)
        let toml = try record(importer, "config.toml"), sibling = try record(importer, "hooks.json")
        checks["detectsInlineGroupsAlongsideStandaloneJSON"] = toml.issue == nil && sibling.issue == nil && toml.preview.contains("SessionStart")
            && toml.preview.contains("Write|Edit") && sibling.preview.contains("公开 JSON 命令")
        checks["previewReportsUnsupportedHandlersAndNeverCopiesTrustOrSecrets"] = toml.preview.contains("PreModelRequest") && toml.preview.contains("Interrupt") && toml.warnings.joined().contains("FutureObserver")
            && toml.warnings.joined().contains("已调整 1 条")
            && importer.preview.contains { $0.standaloneMCPHooks == true && $0.issue?.contains("内嵌凭据") == true && $0.issue?.contains(privateMarker) == false }
            && !(toml.preview + toml.warnings.joined()).contains(privateMarker) && !fm.fileExists(atPath: grants.path)

        try write(projectTOML + "\n# A new configuration version", to: file)
        try importer.begin(.codex, root: incoming, ids: [toml.id, sibling.id], category: .configuration, workspace: project.path)
        try await waitForImport(importer)
        checks["changedInlineSourceDoesNotBlockIndependentJSON"] = importer.batch?.items.contains(where: {
            $0.record.id == toml.id && $0.state == "failed" && $0.detail.contains("来源已变化")
        }) == true && importer.batch?.items.contains(where: { $0.record.id == sibling.id && $0.state == "imported" }) == true
        try write(projectTOML, to: file)
        let scriptBytes = try Data(contentsOf: script)
        await importer.detect(.codex, root: incoming, category: .configuration, workspace: project.path)
        let final = try record(importer, "config.toml")
        checks["rediscoveryKeepsTheAlreadyImportedSibling"] = final.issue == nil && importer.preview.contains { $0.id == sibling.id && $0.issue == "已经导入" }
        try write(projectScript + "\n# A new script version", to: script, mode: 0o751)
        do {
            try await AgentStandaloneDataImport.install(final, root: incoming, store: store)
            checks["changedScriptRejectsTheFrozenPackage"] = false
        } catch {
            checks["changedScriptRejectsTheFrozenPackage"] = error.localizedDescription.contains("资源已变化")
                && (try? AgentStandaloneDataImport.installedURL(final, store: store)) == nil
        }
        try write(projectScript, to: script, mode: 0o751)
        try importer.begin(.codex, root: incoming, ids: [final.id], category: .configuration, workspace: project.path)
        try await waitForImport(importer)
        let installed = try AgentStandaloneDataImport.installedURL(final, store: store)
        let receipt = try store.hooks.importedReceipt(final.targetID, workspace: project.path)
        let config = try Data(contentsOf: installed), copied = installed.deletingLastPathComponent().appendingPathComponent("hooks/start review.sh")
        checks["receiptKeepsOriginalTOMLNameAndCompatibleSettings"] = receipt?.originalName == "config.toml" && receipt?.sourceHash == final.sourceHash
            && String(decoding: config, as: UTF8.self).contains("核对项目报告") && !String(decoding: config, as: UTF8.self).contains(privateMarker)
        let persistedBatch = try Data(contentsOf: profile.appendingPathComponent("imports/batch.json"))
        checks["onlyHookDataAndExecutableScriptAreCopied"] = try Data(contentsOf: copied) == scriptBytes && fm.isExecutableFile(atPath: copied.path)
            && !String(decoding: persistedBatch, as: UTF8.self).contains(privateMarker) && !fm.fileExists(atPath: grants.path)

        try fm.moveItem(at: incoming, to: offline)
        defer { if fm.fileExists(atPath: offline.path) { try? fm.moveItem(at: offline, to: incoming) } }
        let reopened = newStore(), task = reopened.create(title: "项目 Hooks 样例", workspace: project.path, mode: .ask)
        _ = try await AgentGit(store: reopened, taskID: task, directory: AgentGit.metadata(workspace: project.path, creating: true)).initialize()
        let catalog = try reopened.hooks.catalog(workspace: project.path)
        guard let start = catalog.first(where: { $0.source == installed.path && $0.event == .sessionStart }) else { throw PetError("内联 Hook 离线后未载入") }
        let disabled = try await reopened.hooks.fire(.sessionStart, trigger: "disabled", store: reopened, taskID: task, value: "startup")
        checks["importedHandlerNeedsNativeReviewAndDoesNotRunByDefault"] = !reopened.hooks.enabled(start) && disabled.context.isEmpty
            && reopened.task(task)?.events.allSatisfy { $0.hook == nil } == true
        try reopened.hooks.setEnabled(start, true, workspace: project.path)
        let didNotMatch = try await reopened.hooks.fire(.sessionStart, trigger: "nonmatching", store: reopened, taskID: task, value: "compact")
        let keychain = PetKeychain(service: "com.xjs.bluefatfish.inline-hook-check",
                                   configurationFile: output.appendingPathComponent("fixture-model.json"), migrateLegacy: false)
        try keychain.write("PUBLIC-FIXTURE-NO-MODEL", account: "chat")
        let runtime = AgentRuntime(store: reopened, keychain: keychain) {
            var preferences = PetPreferences()
            preferences.endpoint = "http://127.0.0.1:1"
            return preferences
        }
        var blockedRequests = 0
        runtime.modelRequestCheck = { blockedRequests += 1; throw PetError("本机 Hooks 验收拦截模型请求") }
        guard runtime.submit("请准备核对公开文档。", taskID: task) else { throw PetError("未能启动 Hooks 验收任务") }
        let deadline = Date().addingTimeInterval(12)
        while runtime.isRunning(task) && Date() < deadline { await wait(0.025) }
        guard !runtime.isRunning(task) else { runtime.cancel(task); throw PetError("普通任务未完成启动检查") }
        let actual = reopened.task(task)?.events.first { $0.hook?.hookID == start.id }?.hook
        checks["approvedOfflineScriptUsesRealWorkspaceInputAndContextLimit"] = didNotMatch.context.isEmpty
            && start.additionalContextLimit == 8 && actual?.effect?.context == String(originalTitle.prefix(24)) && actual?.exitCode == 0
        checks["normalQuestionTaskUsesHookThenHitsLocalModelGate"] = blockedRequests == 1 && reopened.task(task)?.modelReceipts?.isEmpty != false
        checks["projectHookIsUnavailableOutsideItsOriginalDestination"] = try reopened.hooks.catalog(workspace: other.path).allSatisfy { $0.id != start.id }
            && reopened.hooks.catalog(workspace: nil).allSatisfy { $0.id != start.id }
        let editor = try reopened.hooks.importedDocument(path: installed.path, workspace: project.path)
        try reopened.hooks.saveImportedDocument(editor.0.replacingOccurrences(of: "核对项目报告", with: "检查新版本"),
            path: installed.path, workspace: project.path, expectedHash: editor.1)
        let edited = try reopened.hooks.catalog(workspace: project.path).first { $0.id == start.id }
        checks["editingConvertedTOMLRevokesOriginalApproval"] = edited?.statusMessage == "检查新版本" && edited.map { !reopened.hooks.trusted($0) } == true

        let second = reopened.dataImport
        await second.detect(.codex, root: user, category: .configuration)
        let global = try record(second, "config.toml")
        try second.begin(.codex, root: user, ids: [global.id], category: .configuration)
        try await waitForImport(second)
        guard let userStart = try reopened.hooks.catalog(workspace: nil).first(where: { $0.event == .sessionStart && $0.scope == "导入 · 全局" }) else {
            throw PetError("全局内联 Hook 未载入")
        }
        let freeTask = reopened.create(title: "无工作区 Hooks 样例", mode: .ask)
        try reopened.hooks.setEnabled(userStart, true, workspace: nil)
        let effect = try await reopened.hooks.fire(.sessionStart, trigger: "global", store: reopened, taskID: freeTask)
        checks["userInlineTableWorksWithoutWorkspaceAndOriginalHome"] = effect.context == "PUBLIC USER HOOK 4781"
            && userStart.command.contains("QODER_HOOK_ROOT") && reopened.task(freeTask)?.workspace == nil
        try fm.moveItem(at: offline, to: incoming)
        checks["originalSourceFilesAndProjectDocumentAreByteExact"] = try original.map { try Data(contentsOf: $0) } == inputBytes
            && Data(contentsOf: script) == scriptBytes
            && String(decoding: Data(contentsOf: project.appendingPathComponent("README.md")), as: UTF8.self) == originalTitle + "\n"

        let stateOnly = output.appendingPathComponent("state-only/.codex"), invalid = output.appendingPathComponent("invalid/.codex")
        try write("[hooks.state.fixture]\nenabled = true", to: stateOnly.appendingPathComponent("config.toml"))
        try write("[hooks\nmarker = " + privateMarker, to: invalid.appendingPathComponent("config.toml"))
        await second.detect(.codex, root: stateOnly, category: .configuration)
        checks["trustOnlyTOMLProducesNoHookImport"] = second.preview.isEmpty
        await second.detect(.codex, root: invalid, category: .configuration)
        let malformed = try record(second, "config.toml")
        checks["malformedTOMLReportsFormatWithoutSourceText"] = malformed.issue?.contains("格式无效") == true
            && malformed.issue?.contains(privateMarker) == false
    }
}
