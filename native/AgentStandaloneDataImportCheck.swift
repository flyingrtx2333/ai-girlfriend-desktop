import AppKit

@MainActor extension AppDelegate {
    func runStandaloneDataImportCheck(_ output: URL) async {
        let fm = FileManager.default
        let profile = output.appendingPathComponent("profile")
        let shared = output.appendingPathComponent("shared")
        let incoming = output.appendingPathComponent("original")
        let project = output.appendingPathComponent("harbor")
        let other = output.appendingPathComponent("ridge")
        let category = AgentImportCategory.configuration
        var checks: [String: Bool] = [:]

        func write(_ root: URL, _ name: String, _ content: String) throws {
            let file = root.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file, options: .atomic)
        }
        func contents(_ root: URL, _ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func idle(_ service: AgentDataImport) async throws {
            let deadline = Date().addingTimeInterval(15)
            while service.active, Date() < deadline { await wait(0.03) }
            guard !service.active else { throw PetError("配置迁移未在预期时间完成") }
        }
        func refuses(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func makeStore() -> AgentStore {
            let keychain = PetKeychain(service: "com.xjs.bluefatfish.standalone-import-fixture",
                                       configurationFile: output.appendingPathComponent("fixture-keychain.json"), migrateLegacy: false)
            return AgentStore(directory: profile, legacy: [], extensionHome: shared, mcpKeychain: keychain, hookKeychain: keychain)
        }
        let report = output.appendingPathComponent("standalone-data-import-report.json")
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("本次检查只使用本地样例") }
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            let store = makeStore(), importer = store.dataImport
            let initial = store.tasks.map(\.id)
            let start = "---\nname: overview\ntrigger: always_on\n---\nSHORE_ALWAYS_315\n"
            let manual = "---\nname: checklist\ntrigger: manual\n---\nSHORE_MANUAL_218\n"
            let decision = "---\nname: references\ntrigger: model_decision\ndescription: Choose for source review\n---\nSHORE_DECISION_777\n"
            let matching = "---\nname: sources\ntrigger: glob\nglob: '**/*.swift'\n---\nSHORE_GLOB_491\n"
            let command = "---\nname: Check\ndescription: Read a public reference\n---\nPublic check: $ARGUMENTS\n"
            let instruction = "# Harbor instructions\nUse @README.md when citing.\n"
            try write(incoming, ".qoder/rules/start.md", start)
            try write(incoming, ".qoder/rules/manual.md", manual)
            try write(incoming, ".qoder/rules/model.md", decision)
            try write(incoming, "src/.qoder/rules/swift.md", matching)
            try write(incoming, ".qoder/commands/review/check.md", command)
            try write(incoming, ".qoder/commands/kept.md", "Foreign duplicate\n")
            try write(incoming, "missing/.qoder/rules/remote.md", start)
            try write(incoming, "AGENTS.md", instruction)
            try write(incoming, "AGENTS.local.md", "Skip @/example/outside-source.md\n")
            try write(incoming, "README.md", "PUBLIC HARBOR FACT 665\n")
            try write(incoming, "src/AGENTS.md", "Nested source follows @../README.md\n")
            try write(project, "README.md", "PUBLIC HARBOR FACT 665\n")
            try write(project, "src/public.swift", "// Public Swift fixture\n")
            try write(project, "public.swift", "// Outside the configured folder\n")
            try write(project, ".bluefatfish/commands/kept.md", "Existing local command\n")
            try write(other, "README.md", "DIFFERENT PUBLIC CONTEXT\n")
            try fm.createSymbolicLink(at: incoming.appendingPathComponent(".qoder/rules/link.md"),
                                      withDestinationURL: incoming.appendingPathComponent(".qoder/rules/start.md"))
            for folder in [project, other] {
                // Keep fixture projects independent from the checkout containing the current test run.
                try fm.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
                try store.organization.register(folder.path, mode: .coding)
            }
            await importer.detect(.qoder, root: incoming, category: category)
            checks["projectSourceRequiresTargetBeforeImport"] = importer.preview.contains { $0.issue?.contains("选择目标项目") == true }
                && importer.preview.allSatisfy { $0.issue != nil }
            await importer.detect(.qoder, root: incoming, category: category, workspace: other.path)
            checks["referenceMismatchIsExplained"] = importer.preview.contains { $0.title == "AGENTS.md" && $0.issue?.contains("匹配的指令引用") == true }
            await importer.detect(.qoder, root: incoming, category: category, workspace: project.path)
            let rows = importer.preview
            checks["previewSeparatesFourTriggersAndThreeKinds"] = Set(rows.compactMap { $0.configuration?.kind }) == [.rule, .instruction, .command]
                && Set(rows.filter { $0.configuration?.kind == .rule && $0.issue == nil }.compactMap { $0.warnings.first }) ==
                    ["始终应用", "手动选择", "模型判断", "匹配文件"]
            checks["exposesSkipsBeforeWriting"] = rows.contains { $0.title == "/kept" && $0.issue?.contains("同名命令") == true }
                && rows.contains { $0.title == "link.md" && $0.issue?.contains("普通文件") == true }
                && rows.contains { $0.configuration?.directory == "missing" && $0.issue?.contains("对应目录") == true }
                && rows.contains { $0.title == "AGENTS.local.md" && $0.issue?.contains("超出所选范围") == true }
            let selected = Set(rows.filter { $0.issue == nil && ["overview", "/review:check"].contains($0.title) }.map(\.id))
            checks["previewCannotBeRedirectedToAnotherProject"] = refuses {
                try importer.begin(.qoder, root: incoming, ids: selected, category: category, workspace: other.path)
            }
            importer.onChange = { [weak importer] in
                if importer?.batch?.state == "running", importer?.batch?.items.contains(where: { $0.state == "imported" }) == true { importer?.pause() }
            }
            try importer.begin(.qoder, root: incoming, ids: selected, category: category, workspace: project.path)
            try await idle(importer)
            importer.onChange = nil
            guard let pending = importer.batch?.items.first(where: { $0.state == "pending" }) else { throw PetError("缺少暂停后的剩余定义") }
            checks["pausePreservesSelectedRowsOnly"] = importer.batch?.state == "paused" && importer.batch?.items.count == 2
                && !fm.fileExists(atPath: project.appendingPathComponent("AGENTS.md").path) && store.tasks.map(\.id) == initial
            try await AgentStandaloneDataImport.install(pending.record, root: incoming, store: store)
            let offline = output.appendingPathComponent("temporarily-offline")
            try fm.moveItem(at: incoming, to: offline)
            defer { if fm.fileExists(atPath: offline.path) { try? fm.moveItem(at: offline, to: incoming) } }
            let reopened = makeStore(), resumed = reopened.dataImport
            resumed.resume()
            try await idle(resumed)
            checks["alreadyWrittenPendingItemResumesWithSourceOffline"] = resumed.batch?.state == "completed"
                && resumed.batch?.items.filter { $0.state == "imported" }.count == 2
            checks["offlineBatchLinksToExactInstalledFiles"] = resumed.batch?.items.allSatisfy {
                (try? AgentStandaloneDataImport.installedURL($0.record, store: reopened).path.hasPrefix(project.path + "/")) == true
            } == true
            try fm.moveItem(at: offline, to: incoming)
            await resumed.detect(.qoder, root: incoming, category: category, workspace: project.path)
            checks["repeatedDetectionRecognizesExistingBytes"] = resumed.preview.filter { $0.issue == "已经导入" }.count == 2
            let remaining = Set(resumed.preview.filter { $0.issue == nil }.map(\.id))
            try resumed.begin(.qoder, root: incoming, ids: remaining, category: category, workspace: project.path)
            try await idle(resumed)
            checks["allRemainingCompatibleDefinitionsImported"] = resumed.batch?.items.count == 5
                && resumed.batch?.items.allSatisfy { $0.state == "imported" } == true
            checks["sourceAndExistingDestinationArePreserved"] = try contents(incoming, "AGENTS.md") == instruction
                && contents(incoming, ".qoder/rules/start.md") == start
                && contents(project, ".bluefatfish/commands/kept.md") == "Existing local command\n"
                && contents(project, "src/.bluefatfish/rules/swift.md") == matching
                && !fm.fileExists(atPath: project.appendingPathComponent("missing").path)
            let projectTask = reopened.create(title: "公开项目验收", workspace: project.path, mode: .ask)
            let otherTask = reopened.create(title: "其他项目验收", workspace: other.path)
            let generalTask = reopened.create(title: "无工作区验收", mode: .ask)
            guard let task = reopened.task(projectTask), let unrelated = reopened.task(otherTask), let general = reopened.task(generalTask) else {
                throw PetError("验收任务未找到")
            }
            let baseline = try reopened.rules.context(task)
            checks["savedRulesRetainNativeActivationModes"] = baseline.text.contains("SHORE_ALWAYS_315")
                && baseline.text.contains("Choose for source review") && !baseline.text.contains("SHORE_DECISION_777")
                && !baseline.text.contains("SHORE_MANUAL_218") && !baseline.text.contains("SHORE_GLOB_491")
            try reopened.rules.accessRules("public.swift", store: reopened, taskID: projectTask)
            let outside = try reopened.rules.context(reopened.task(projectTask) ?? task)
            try reopened.rules.accessRules("src/public.swift", store: reopened, taskID: projectTask)
            try reopened.instructions.access("src/public.swift", store: reopened, taskID: projectTask)
            let nested = reopened.task(projectTask) ?? task
            let scoped = try reopened.rules.context(nested)
            checks["nestedRuleMatchesRelativeToItsOriginalFolder"] = !outside.text.contains("SHORE_GLOB_491") && scoped.text.contains("SHORE_GLOB_491")
            let active = reopened.instructions.report(nested)
            checks["instructionsAndReferencesLoadWithTheirProjectAndRelativePaths"] = active.issues.isEmpty
                && active.text.contains("Harbor instructions") && active.text.contains("Nested source follows") && active.text.contains("PUBLIC HARBOR FACT 665")
                && !reopened.instructions.report(unrelated).text.contains("Harbor instructions")
            let message = AgentMessage(role: "user", content: "/review:check public facts")
            let expanded = try reopened.extensions.expand(message, store: reopened, taskID: projectTask)
            checks["slashCommandUsesNativeExpansionAndStaysInItsProject"] = expanded.extensionInstructions?.contains("Public check: public facts") == true
                && refuses { _ = try reopened.extensions.expand(message, store: reopened, taskID: otherTask) }
                && refuses { _ = try reopened.extensions.expand(message, store: reopened, taskID: generalTask) }

            try write(shared, ".qoder/rules/shared.md", start.replacingOccurrences(of: "overview", with: "shared"))
            let sharedConfig = shared.appendingPathComponent(".qoder")
            await resumed.detect(.qoder, root: sharedConfig, category: category)
            checks["liveQoderConfigurationIsSharedWithoutCopy"] = resumed.preview.count == 1 && resumed.preview.first?.issue == "已共享"
                && !fm.fileExists(atPath: profile.appendingPathComponent("extensions/rules/shared.md").path)

            let codex = output.appendingPathComponent("portable/.codex")
            try write(codex, "AGENTS.md", "CODEX LOWER PRIORITY\n")
            try write(codex, "AGENTS.override.md", "CODEX EFFECTIVE INSTRUCTIONS\n")
            try write(codex, "prompts/outline.md", "---\ndescription: Public outline\n---\nBuild a short outline.\n")
            try write(codex, "prompts/with-arg.md", "Refer to $1 and $FILE.\n")
            try write(codex, "rules/default.rules", "# Public policy sample\n")
            await resumed.detect(.codex, root: codex, category: category)
            checks["codexUsesEffectiveOverrideAndReportsUnsupportedPoliciesAndParameters"] = resumed.preview.count == 4
                && resumed.preview.contains { $0.title == "AGENTS.override.md" && $0.configuration?.relative == "AGENTS.md" && $0.issue == nil }
                && resumed.preview.contains { $0.issue?.contains("审批策略") == true }
                && resumed.preview.contains { $0.issue?.contains("参数占位符") == true }
            try resumed.begin(.codex, root: codex, ids: Set(resumed.preview.filter { $0.issue == nil }.map(\.id)), category: category)
            try await idle(resumed)
            let prompt = try reopened.extensions.expand(AgentMessage(role: "user", content: "/prompts:outline"), store: reopened, taskID: generalTask)
            checks["globalCodexInstructionsAndStaticPromptWorkWithNoWorkspace"] = reopened.instructions.report(general).text.contains("CODEX EFFECTIVE INSTRUCTIONS")
                && prompt.extensionInstructions?.contains("Build a short outline.") == true
                && resumed.batch?.items.allSatisfy { $0.state == "imported" } == true
            checks["policyAndParameterizedPromptWereNeverPublished"] = !fm.fileExists(atPath: profile.appendingPathComponent("extensions/commands/prompts/with-arg.md").path)
                && !fm.fileExists(atPath: profile.appendingPathComponent("extensions/rules/default.rules").path)
                && !fm.fileExists(atPath: output.appendingPathComponent("fixture-keychain.json").path)

            let moving = output.appendingPathComponent("fresh-export")
            try write(moving, ".qoder/commands/changed.md", "Before detection\n")
            try write(moving, ".qoder/commands/race.md", "Incoming file\n")
            try write(moving, "AGENTS.md", "Cite @README.md\n")
            try write(moving, "README.md", "DIFFERENT PUBLIC CONTEXT\n")
            await resumed.detect(.qoder, root: moving, category: category, workspace: other.path)
            let pendingIDs = Set(resumed.preview.filter { $0.issue == nil }.map(\.id))
            try write(moving, ".qoder/commands/changed.md", "Changed after detection\n")
            try write(other, ".bluefatfish/commands/race.md", "Created locally after detection\n")
            try write(other, "README.md", "Changed target reference\n")
            try resumed.begin(.qoder, root: moving, ids: pendingIDs, category: category, workspace: other.path)
            try await idle(resumed)
            let failures = resumed.batch?.items.filter { $0.state == "failed" } ?? []
            checks["sourceAndDestinationChangesAfterPreviewAreReported"] = failures.count == 3
                && failures.contains { $0.detail.contains("来源已变化") }
                && failures.contains { $0.detail.contains("目标文件已存在") }
                && failures.contains { $0.detail.contains("匹配的指令引用") }
            checks["staleOrConflictingItemsNeverOverwriteOrPublish"] = try contents(other, ".bluefatfish/commands/race.md") == "Created locally after detection\n"
                && !fm.fileExists(atPath: other.appendingPathComponent(".bluefatfish/commands/changed.md").path)
                && !fm.fileExists(atPath: other.appendingPathComponent("AGENTS.md").path)
            let final: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks, "modelRequests": 0]
            try JSONSerialization.data(withJSONObject: final, options: [.sortedKeys, .prettyPrinted]).write(to: report, options: .atomic)
        } catch {
            let final: [String: Any] = ["success": false, "checks": checks, "error": error.localizedDescription, "modelRequests": 0]
            try? JSONSerialization.data(withJSONObject: final, options: [.sortedKeys, .prettyPrinted]).write(to: report, options: .atomic)
        }
    }
}
