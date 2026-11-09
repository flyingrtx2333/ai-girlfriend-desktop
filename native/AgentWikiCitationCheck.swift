import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiCitationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "fixture": "Actual project documents and assets, manually arranged as Wiki files; not AI-generated output"]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("引用设置检查不调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            runtime.modelRequestCheck = { throw PetError("引用设置检查不得发送模型请求") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), other = output.appendingPathComponent("other-workspace")
            let owner = tasks.create(title: "Wiki 自动引用", workspace: workspace.path, mode: .agent), otherID = tasks.create(title: "另一个项目", workspace: other.path, mode: .ask)
            tasks.update(owner) { $0.draft = "保留的 Wiki 引用草稿"; $0.toolGroups = ["knowledge"] }
            tasks.update(otherID) { $0.draft = "另一个项目的原草稿" }
            let cards = tasks.knowledgeCards; var cardOptions = try cards.options(workspace: workspace.path); cardOptions.citation = false
            try cards.setOptions(cardOptions, workspace: workspace.path, expected: cards.settings().1)
            let cardSettings = try cards.settings().1, files = try AgentFiles(workspace: workspace.path)
            let originals = try Dictionary(uniqueKeysWithValues: AgentWiki.pages(workspace: workspace.path).map { ($0, try files.fileHash(files.resolve($0), maximum: 512_000)) })
            func task() -> AgentTaskRecord { tasks.task(owner)! }
            func names(_ task: AgentTaskRecord) throws -> Set<String> { Set(try runtime.toolDefinitions(task, preferences: store.preferences).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) }
            func hint() throws -> Bool { try runtime.systemContext(task()).contains("当前项目有 Repo Wiki") }
            func call(_ name: String, taskID: String? = nil, args: [String: Any] = [:]) async throws -> AgentToolResult {
                try await AgentTools(store: tasks, taskID: taskID ?? owner).execute(AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
            }
            let initial = try AgentWiki.citation(store: tasks, workspace: workspace.path), originalListing = try await call("project_wiki")
            checks["defaultsOnAndActualWikiIsAvailable"] = try initial.enabled && hint() && names(task()).contains("project_wiki") && originalListing.text.contains("index.md") && originals.count >= 3
            try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: initial.signature)
            checks["disableRemovesAutomaticHintAndModelTool"] = try !hint() && !names(task()).contains("project_wiki")
            let loaded = try await call("load_tools", args: ["groups": ["knowledge"]])
            checks["toolLoadingCannotAdvertiseDisabledWiki"] = !loaded.text.contains("project_wiki")
            do { _ = try await call("project_wiki"); checks["staleWikiToolIsRejectedBeforeReading"] = false } catch { checks["staleWikiToolIsRejectedBeforeReading"] = error.localizedDescription.contains("关闭 Wiki 自动引用") }
            checks["documentReadingRemainsAvailable"] = try AgentWiki.view(store: tasks, taskID: owner, language: "zh").pages.count == originals.count
            let generation = tasks.create(title: "生成工具范围检查，不调用模型", workspace: workspace.path, mode: .goal); tasks.update(generation) { $0.kind = "wiki" }
            let generationListing = try await call("project_wiki", taskID: generation), generationNames = try names(tasks.task(generation)!)
            checks["generationCanStillReviewExistingWiki"] = AgentWiki.citationAllowed(store: tasks, task: tasks.task(generation)!) && generationNames.contains("project_wiki") && generationListing.text.contains("index.md")
            let noProject = tasks.create(title: "无项目问答", mode: .ask); tasks.update(noProject) { $0.toolGroups = ["terminal", "knowledge"] }
            let noProjectNames = try names(tasks.task(noProject)!)
            checks["noWorkspaceAskStillHasTerminalWithoutWiki"] = noProjectNames.contains("run_command") && !noProjectNames.contains("project_wiki")
            let off = try AgentWiki.citation(store: tasks, workspace: workspace.path)
            try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: true, expected: off.signature)
            checks["reenableRestoresActualWikiHintAndTool"] = try hint() && names(task()).contains("project_wiki")
            checks["cardCitationSettingsRemainIndependent"] = try cards.settings().1 == cardSettings && !cards.options(workspace: workspace.path).citation
            let beforeOther = try AgentWiki.citation(store: tasks, workspace: workspace.path)
            try AgentWiki.setCitation(store: tasks, workspace: other.path, enabled: false, expected: beforeOther.signature)
            checks["workspaceCitationIsIndependent"] = try AgentWiki.citation(store: tasks, workspace: workspace.path).enabled && !AgentWiki.citation(store: tasks, workspace: other.path).enabled
            let settings = tasks.directory.deletingLastPathComponent().appendingPathComponent("wiki/settings.json"), settingsFiles = try AgentFiles(workspace: settings.deletingLastPathComponent().path), valid = try settingsFiles.readData(settings, maximum: 1_000_000)
            guard let savedPermissions = try fm.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber else { throw PetError("无法读取引用设置权限") }
            checks["settingsUsePrivateFilePermissions"] = savedPermissions.intValue == 0o600
            do { try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: beforeOther.signature); checks["staleSettingsCannotOverwriteOtherWorkspaceChanges"] = false } catch { checks["staleSettingsCannotOverwriteOtherWorkspaceChanges"] = try settingsFiles.readData(settings, maximum: 1_000_000) == valid }
            let reloaded = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["citationSurvivesStoreReload"] = try AgentWiki.citation(store: reloaded, workspace: workspace.path).enabled && !AgentWiki.citation(store: reloaded, workspace: other.path).enabled
            let invalid = Data("{\"version\":2,\"projects\":{}}".utf8); try settingsFiles.writeData(invalid, to: settings, permissions: savedPermissions.intValue)
            checks["invalidSettingsFailClosedForContextAndTools"] = try !AgentWiki.citationAllowed(store: tasks, task: task()) && !hint() && !names(task()).contains("project_wiki")
            do { try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: true, expected: AgentFiles.hash(invalid)); checks["invalidSettingsAreNotOverwritten"] = false } catch { checks["invalidSettingsAreNotOverwritten"] = try settingsFiles.readData(settings, maximum: 1_000_000) == invalid }
            try settingsFiles.writeData(valid, to: settings, permissions: savedPermissions.intValue)
            let directory = settings.deletingLastPathComponent(), held = output.appendingPathComponent("held-wiki-settings"), outside = output.appendingPathComponent("unrelated-settings")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true); try valid.write(to: outside.appendingPathComponent("settings.json"))
            try fm.moveItem(at: directory, to: held); try fm.createSymbolicLink(at: directory, withDestinationURL: outside)
            do { try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: AgentFiles.hash(valid)); checks["settingsDirectorySymlinkCannotRedirectWrites"] = false } catch { checks["settingsDirectorySymlinkCannotRedirectWrites"] = try Data(contentsOf: outside.appendingPathComponent("settings.json")) == valid }
            try fm.removeItem(at: directory); try fm.moveItem(at: held, to: directory)
            let heldFile = output.appendingPathComponent("held-settings.json"); try fm.moveItem(at: settings, to: heldFile); try fm.createSymbolicLink(at: settings, withDestinationURL: outside.appendingPathComponent("settings.json"))
            do { try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: AgentFiles.hash(valid)); checks["settingsFileSymlinkCannotRedirectWrites"] = false } catch { checks["settingsFileSymlinkCannotRedirectWrites"] = try Data(contentsOf: outside.appendingPathComponent("settings.json")) == valid }
            try fm.removeItem(at: settings); try fm.moveItem(at: heldFile, to: settings)
            checks["allActualWikiDocumentsRemainUntouched"] = try originals.allSatisfy { try files.fileHash(files.resolve($0.key), maximum: 512_000) == $0.value }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 引用前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: ".bluefatfish/wiki/index.md") else { throw PetError("Wiki 窗口未打开") }
            records.enableWikiGeneration { _ in try? write(["unexpected": true, "modelsCalled": false], "unexpected-generation.json") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": owner, "workspace": workspace.path, "otherWorkspace": other.path, "settings": settings.path, "checks": checks, "modelsCalled": false], "wiki-citation-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-citation-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-citation-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); state["modelHasWikiTool"] = try names(task()).contains("project_wiki"); state["automaticWikiHint"] = try hint(); state["citationAllowed"] = AgentWiki.citationAllowed(store: tasks, task: task()); state["cardSettingsHash"] = try cards.settings().1
                    try write(state, "native-wiki-citation-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-citation-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] {
                report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == hash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui
            }
            checks["bothComposerDraftsAndCardSettingsUnchanged"] = try tasks.task(owner)?.draft == "保留的 Wiki 引用草稿" && tasks.task(otherID)?.draft == "另一个项目的原草稿" && cards.settings().1 == cardSettings
            checks["noModelMessagesOrReceiptsOrGeneration"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty } && !fm.fileExists(atPath: output.appendingPathComponent("unexpected-generation.json").path)
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "wiki-citation-report.json")
    }
}
