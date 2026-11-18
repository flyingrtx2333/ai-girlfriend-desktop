import AppKit

@MainActor extension AppDelegate {
    func runExecutionImportCheck(_ output: URL) async {
        let fm = FileManager.default, profile = output.appendingPathComponent("profile")
        let shared = output.appendingPathComponent("shared-home"), incoming = output.appendingPathComponent("qoder-export")
        let project = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("ridge")
        let report = output.appendingPathComponent("execution-import-report.json")
        let credentialFile = output.appendingPathComponent("fixture-vault.json")
        let marker = "PUBLIC-SOURCE-HEADER-3094"
        var checks: [String: Bool] = [:]

        func write(_ bytes: Data, _ root: URL, _ path: String, mode: Int? = nil) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        }
        func json(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        func makeStore() -> AgentStore {
            let vault = PetKeychain(service: "com.xjs.bluefatfish.execution-import-check", configurationFile: credentialFile, migrateLegacy: false)
            return AgentStore(directory: profile, legacy: [], extensionHome: shared, mcpKeychain: vault, hookKeychain: vault)
        }
        func idle(_ service: AgentDataImport) async throws {
            let deadline = Date().addingTimeInterval(14)
            while service.active && Date() < deadline { await wait(0.03) }
            guard !service.active else { throw PetError("扩展配置迁移未结束") }
        }
        func denied(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func emit(_ issue: String? = nil) {
            var value: [String: Any] = ["success": issue == nil && checks.values.allSatisfy { $0 }, "checks": checks, "modelRequests": 0]
            value["error"] = issue
            try? json(value).write(to: report, options: .atomic)
        }

        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("迁移专项使用公开本机样例") }
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            let store = makeStore(), importer = store.dataImport
            let taskIDs = store.tasks.map(\.id)
            for root in [project, other] {
                try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
                try store.organization.register(root.path, mode: .coding)
            }
            let global = AgentProfile(name: "global-reader", description: "Existing user definition", instructions: "Keep global instructions")
            let existing = AgentProfile(name: "kept", description: "Existing project definition", instructions: "Keep original project instructions")
            try store.agents.save(store.agents.encode([global]), expectedHash: nil)
            try store.agents.save(store.agents.encode([existing]), expectedHash: nil, workspace: project.path)
            let globalBefore = try store.agents.document().1
            let localConfig = ["hooks": ["SessionEnd": [["hooks": [["name": "既有结束时间记录", "type": "command", "command": "/usr/bin/true"]]]]]]
            try store.hooks.save(String(decoding: json(localConfig), as: UTF8.self), project: true, workspace: project.path, expectedHash: nil)
            guard let oldHook = try store.hooks.catalog(workspace: project.path).first(where: { $0.name == "既有结束时间记录" }) else { throw PetError("缺少既有 Hook") }
            try store.hooks.setEnabled(oldHook, true, workspace: project.path)
            let grants = profile.appendingPathComponent("extensions/hook-settings.json"), grantsBefore = try Data(contentsOf: grants)
            let fixture = "---\nname: qoder-reader\ndescription: Public project reader\ntools: [Read, Grep, Glob, Bash]\ndisallowedTools: [Bash]\npermissionMode: bypassPermissions\n---\nCite the verified public document.\n"
            try write(Data(fixture.utf8), incoming, ".qoder/agents/reader.md")
            try write(Data(fixture.replacingOccurrences(of: "qoder-reader", with: "kept").utf8), incoming, ".qoder/agents/kept.md")
            let documentation = "PUBLIC HARBOR CONTENT 7213"
            try write(Data((documentation + "\n").utf8), project, "README.md")
            let script = Data("#!/bin/sh\nprintf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"PUBLIC LOCAL HOOK 4872\"}}'\n".utf8)
            try write(script, incoming, ".qoder/hooks/public-check.sh", mode: 0o755)
            let hookConfig = try json(["hooks": [
                "SessionStart": [["hooks": [["name": "公开项目检查", "type": "command", "command": "\"$QODER_HOOK_ROOT/public-check.sh\"", "timeout": 5]]]],
                "Stop": [["hooks": [
                    ["name": "等待本机凭据", "type": "http", "url": "https://example.com/public-check", "headers": ["X-Test": marker]],
                    ["name": "内嵌参数示例", "type": "command", "command": "/usr/bin/true --token " + marker]
                ]]],
                "UnknownEvent": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]
            ], "mcpServers": ["unused": ["env": ["PRIVATE_FIXTURE": marker]]]])
            try write(hookConfig, incoming, ".qoder/settings.json")
            try write(try json(["profile": ["ignored": marker]]), incoming, ".qoder/settings.local.json")

            await importer.detect(.qoder, root: incoming, category: .configuration)
            checks["bothKindsRequireProjectScope"] = importer.preview.contains { $0.configuration?.kind == .agent }
                && importer.preview.contains { $0.configuration?.kind == .hooks } && importer.preview.allSatisfy { $0.issue?.contains("选择目标项目") == true }
            await importer.detect(.qoder, root: incoming, category: .configuration, workspace: project.path)
            let rows = importer.preview
            checks["previewKeepsExistingNamesAndShowsSupportedHandlers"] = rows.count == 3 && rows.contains { $0.title == "kept" && $0.issue?.contains("同名智能体") == true }
                && rows.contains { $0.preview.contains("公开项目检查") && $0.warnings.contains(where: { $0.contains("跳过 2 项") }) }
            checks["previewDoesNotRevealSourceCredentials"] = rows.allSatisfy { !$0.preview.contains(marker) && !$0.warnings.joined().contains(marker) }
            let selected = Set(rows.filter { $0.issue == nil }.map(\.id))
            importer.onChange = { [weak importer] in
                if importer?.batch?.state == "running", importer?.batch?.items.contains(where: { $0.state == "imported" }) == true { importer?.pause() }
            }
            try importer.begin(.qoder, root: incoming, ids: selected, category: .configuration, workspace: project.path)
            try await idle(importer)
            importer.onChange = nil
            guard let pending = importer.batch?.items.first(where: { $0.state == "pending" }),
                  let agent = importer.batch?.items.first(where: { $0.record.configuration?.kind == .agent }),
                  let hook = importer.batch?.items.first(where: { $0.record.configuration?.kind == .hooks }) else { throw PetError("缺少暂停的选中配置") }
            checks["pausePersistedExactlySelectedRows"] = importer.batch?.state == "paused" && importer.batch?.items.count == 2 && store.tasks.map(\.id) == taskIDs
            try await AgentStandaloneDataImport.install(pending.record, root: incoming, store: store)
            let offline = output.appendingPathComponent("qoder-export-offline")
            try fm.moveItem(at: incoming, to: offline)
            defer { if fm.fileExists(atPath: offline.path) { try? fm.moveItem(at: offline, to: incoming) } }
            let reopened = makeStore(), resumed = reopened.dataImport
            resumed.resume(); try await idle(resumed)
            checks["copiedRoleAndHooksResumeWhileSourceOffline"] = resumed.batch?.state == "completed" && resumed.batch?.items.allSatisfy { $0.state == "imported" } == true
            guard let role = AgentStandaloneDataImport.installedProfile(agent.record, store: reopened) else { throw PetError("原项目智能体未载入") }
            let config = try AgentStandaloneDataImport.installedURL(hook.record, store: reopened)
            let loaded = try reopened.hooks.catalog(workspace: project.path).filter { $0.source == config.path }
            guard let handler = loaded.first(where: { $0.name == "公开项目检查" }), let http = loaded.first(where: { $0.name == "等待本机凭据" }) else { throw PetError("已导入处理器未载入") }
            let installedBytes = try Data(contentsOf: config), journal = try Data(contentsOf: profile.appendingPathComponent("imports/batch.json"))
            checks["copyDoesNotPersistSourceCredentialsOrChangeExistingGrants"] = try !String(decoding: installedBytes + journal, as: UTF8.self).contains(marker)
                && String(decoding: installedBytes, as: UTF8.self).contains(AgentHookCredentials.placeholder)
                && Data(contentsOf: grants) == grantsBefore && reopened.hooks.trusted(oldHook) && !fm.fileExists(atPath: credentialFile.path)
            checks["copiedScriptKeepsBytesAndExecutableMode"] = try Data(contentsOf: URL(fileURLWithPath: handler.root).appendingPathComponent("public-check.sh")) == script
                && fm.isExecutableFile(atPath: handler.root + "/public-check.sh")
            checks["bothKindsInitiallyDisabledAndProtectedByNativeApproval"] = !role.enabled && role.permission == .review && !reopened.hooks.enabled(handler)
                && http.diagnostic?.contains("未配置") == true && denied { try reopened.hooks.setEnabled(http, true, workspace: project.path) }
            checks["roleAndHookAreInvisibleInOtherProjectAndGeneralTask"] = try reopened.agents.list(workspace: other.path).allSatisfy { $0.id != role.id }
                && reopened.agents.list().allSatisfy { $0.id != role.id }
                && reopened.hooks.catalog(workspace: other.path).allSatisfy { $0.id != handler.id }
                && reopened.hooks.catalog(workspace: nil).allSatisfy { $0.id != handler.id }
            let noTrigger = reopened.create(title: "停用流程", workspace: project.path, mode: .ask)
            let empty = try await reopened.hooks.fire(.sessionStart, trigger: "before-review", store: reopened, taskID: noTrigger)
            checks["disabledHookDoesNotRunAtItsOwnEvent"] = empty.context.isEmpty && reopened.task(noTrigger)?.events.contains(where: { $0.hook != nil }) == false
            try reopened.agents.setEnabled(role.id, true, workspace: project.path)
            let task = try reopened.agents.createTask(role.id, store: reopened, workspace: project.path)
            let tool = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"README.md\"}")
            let result = try await AgentTools(store: reopened, taskID: task).execute(tool)
            checks["enabledRoleReadsActualProjectThroughNativeTool"] = result.text.contains(documentation)
                && reopened.task(task)?.agent?.profile.instructions == "Cite the verified public document."
                && Set(role.tools) == ["list_directory", "read_file", "search_files"]
                && denied { _ = try reopened.agents.createTask(role.id, store: reopened, workspace: other.path) }
            try reopened.hooks.setEnabled(handler, true, workspace: project.path)
            let effect = try await reopened.hooks.fire(.sessionStart, trigger: "after-review", store: reopened, taskID: task)
            checks["enabledHookActuallyRunsCopiedScriptWithSourceOffline"] = effect.context.contains("PUBLIC LOCAL HOOK 4872")
                && reopened.task(task)?.events.contains { $0.hook?.hookID == handler.id && $0.hook?.exitCode == 0 } == true
            let edit = try reopened.hooks.importedDocument(path: config.path, workspace: project.path)
            let edited = edit.0.replacingOccurrences(of: AgentHookCredentials.placeholder, with: "PUBLIC-RECONFIGURED-HEADER")
                .replacingOccurrences(of: "公开项目检查", with: "更新项目检查")
            try reopened.hooks.saveImportedDocument(edited, path: config.path, workspace: project.path, expectedHash: edit.1)
            let current = try reopened.hooks.catalog(workspace: project.path)
            checks["editingImportedHooksRequiresReReviewAndPreservesOtherGrants"] = current.contains { $0.id == handler.id && $0.name == "更新项目检查" && !reopened.hooks.trusted($0) }
                && current.contains { $0.id == oldHook.id && reopened.hooks.trusted($0) }
            try fm.moveItem(at: offline, to: incoming)
            checks["originalFilesAndGlobalRoleDocumentRemainUnchanged"] = try Data(contentsOf: incoming.appendingPathComponent(".qoder/settings.json")) == hookConfig
                && Data(contentsOf: incoming.appendingPathComponent(".qoder/hooks/public-check.sh")) == script && reopened.agents.document().1 == globalBefore
            await resumed.detect(.qoder, root: incoming, category: .configuration, workspace: project.path)
            checks["rediscoveryRecognizesTheSameRoleAndHookFiles"] = resumed.preview.filter { $0.issue == "已经导入" }.count == 2

            let codex = output.appendingPathComponent("portable/.codex")
            let toml = """
            name = "codex-archivist"
            description = "Public archival review"
            developer_instructions = "Find the supplied records."
            sandbox_mode = "read-only"
            model_reasoning_effort = "high"
            [features]
            shell_tool = false
            """
            try write(Data(toml.utf8), codex, "agents/archive.toml")
            let codexHooks = try json(["hooks": [
                "PreToolUse": [["matcher": "^apply_patch$", "hooks": [["type": "command", "command": "/usr/bin/true"]]]],
                "PreModelRequest": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]
            ]])
            try write(codexHooks, codex, "hooks.json")
            await resumed.detect(.codex, root: codex, category: .configuration)
            checks["codexPreviewConvertsTOMLRoleAndExplainsUnsupportedHooks"] = resumed.preview.count == 2
                && resumed.preview.contains { $0.title == "codex-archivist" && $0.preview.contains("只读项目") && !$0.preview.contains("run_command") }
                && resumed.preview.contains { $0.preview.contains("Write|Edit") && $0.warnings.joined().contains("PreModelRequest") }
            try resumed.begin(.codex, root: codex, ids: Set(resumed.preview.filter { $0.issue == nil }.map(\.id)), category: .configuration)
            try await idle(resumed)
            checks["codexRoleAndHookLoadInUserScopeWithNativeRestrictions"] = try reopened.agents.list().contains { $0.name == "codex-archivist" && !$0.enabled && $0.readOnly
                && !$0.tools.contains("run_command") && $0.sourceWorkspace == nil }
                && reopened.hooks.catalog(workspace: nil).contains { $0.matcher == "Write|Edit" && $0.timeout == 600 && !reopened.hooks.enabled($0) }
                && resumed.batch?.items.allSatisfy { $0.state == "imported" } == true
            emit()
        } catch { emit(error.localizedDescription) }
    }
}
