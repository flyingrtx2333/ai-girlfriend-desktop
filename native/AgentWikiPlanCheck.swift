import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiPlanCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "documents": "Manually imported actual repository documents; no model-generated output or completion messages"]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("本项只检查实际本地文件和界面，不调用模型") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            let config = try AgentWikiPlan.load(files: files), compatible = try files.readData(files.resolve(AgentWikiPlan.compatiblePath))
            checks["compatibleConfigurationReadWithoutWritingOwnFile"] = config.path == AgentWikiPlan.compatiblePath && config.plan.documents?.count == 2 && !fm.fileExists(atPath: workspace.appendingPathComponent(AgentWikiPlan.configurationPath).path)
            let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-plan-vectors.json"))) as! [String: String]
            for (name, text) in vectors { do { _ = try AgentWikiPlan.parse(text); checks[name] = false } catch { checks[name] = true } }
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }; _ = control
            let owner = tasks.create(title: "Wiki 规划与语言", workspace: workspace.path, mode: .agent); tasks.update(owner) { $0.draft = "保留的规划验收草稿" }
            let branch = try tasks.knowledgeCards.scope(tasks.task(owner)!).branch
            let id = tasks.create(title: "手工导入文档协议检查", workspace: workspace.path, mode: .goal)
            tasks.update(id) { $0.kind = "wiki"; $0.wikiJob = AgentWikiJob(language: "zh", branch: branch, root: AgentWiki.root(branch: branch, language: "zh", taskID: id), configurationHash: config.hash, plan: config.plan) }
            func call(_ taskID: String, _ name: String, _ args: [String: Any] = [:]) async throws -> AgentToolResult {
                let value = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)), tools = AgentTools(store: tasks, taskID: taskID)
                return try await tools.execute(value)
            }
            _ = try await call(id, "index_project")
            do { _ = try await call(id, "plan_wiki", ["documents": [["title": "替换", "goal": "替换"]]]); checks["configuredPlanCannotBeReplaced"] = false } catch { checks["configuredPlanCannotBeReplaced"] = true }
            let root = tasks.task(id)!.wikiJob!.root, paths = try config.plan.paths(root: root), first = paths[config.plan.documents![0].title]!, second = paths[config.plan.documents![1].title]!
            _ = try await call(id, "read_file", ["path": "README.md", "offset": 1, "limit": 8])
            let original = try String(contentsOf: files.resolve("README.md"), encoding: .utf8), excerpt = original.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
            let citation = String(repeating: "../", count: root.split(separator: "/").count) + "README.md#L1-L4"
            for doc in config.plan.documents! { _ = try await call(id, "write_file", ["path": paths[doc.title]!, "content": "# " + doc.title + "\n\n" + excerpt + "\n\n[实际 README 原文](" + citation + ")\n"]) }
            _ = try await call(id, "read_file", ["path": first, "limit": 1]); _ = try await call(id, "read_file", ["path": second, "limit": 200])
            do { _ = try AgentWiki.validatePlanned(tasks.task(id)!); checks["partialReadbackCannotValidatePage"] = false } catch { checks["partialReadbackCannotValidatePage"] = true }
            _ = try await call(id, "read_file", ["path": first, "limit": 200])
            let checked = try AgentWiki.validatePlanned(tasks.task(id)!)
            checks["actualSourceReadWriteAndFullReadbackValidated"] = checked.hashes.count == 2 && checked.sources == ["README.md"]
            do { _ = try await call(id, "write_file", ["path": first, "content": "未经哈希核对的覆盖"]); checks["overwriteRequiresCurrentHash"] = false } catch { checks["overwriteRequiresCurrentHash"] = true }
            for (name, path) in [("sourceWritesRejected", "README.md"), ("otherLanguageWritesRejected", AgentWiki.root(branch: branch, language: "en", taskID: id) + "/index.md")] {
                do { _ = try await call(id, "write_file", ["path": path, "content": "禁止写入"]); checks[name] = false } catch { checks[name] = true }
            }
            let beforePage = try files.readData(files.resolve(first)), invalid = String(decoding: beforePage, as: UTF8.self).replacingOccurrences(of: "#L1-L4", with: "#L9999")
            _ = try await call(id, "write_file", ["path": first, "content": invalid, "expected_hash": checked.hashes[first]!]); _ = try await call(id, "read_file", ["path": first, "limit": 200])
            do { _ = try AgentWiki.validatePlanned(tasks.task(id)!); checks["unreadCitationLinesRejected"] = false } catch { checks["unreadCitationLinesRejected"] = true }
            _ = try await call(id, "write_file", ["path": first, "content": String(decoding: beforePage, as: UTF8.self), "expected_hash": AgentFiles.hash(Data(invalid.utf8))]); _ = try await call(id, "read_file", ["path": first, "limit": 200])
            tasks.update(id) { $0.status = .completed }
            do { try await AgentWiki.finalizePlanned(store: tasks, taskID: id); checks["noPublicationWithoutActualCompletionCall"] = false } catch { checks["noPublicationWithoutActualCompletionCall"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh") == nil }
            let automatic = tasks.create(title: "自动规划协议检查", workspace: workspace.path, mode: .goal)
            tasks.update(automatic) { $0.kind = "wiki"; $0.wikiJob = AgentWikiJob(language: "en", branch: branch, root: AgentWiki.root(branch: branch, language: "en", taskID: automatic), configurationHash: nil, plan: AgentWikiPlan()) }
            do { _ = try await call(automatic, "plan_wiki", ["documents": [["title": "Overview", "goal": "Read actual files"]]]); checks["automaticPlanningRequiresActualIndex"] = false } catch { checks["automaticPlanningRequiresActualIndex"] = true }
            _ = try await call(automatic, "index_project"); _ = try await call(automatic, "plan_wiki", ["documents": [["title": "Overview", "goal": "Read actual files"], ["title": "Sources", "goal": "Read sources", "parent": "Overview"]]])
            do { _ = try await call(automatic, "plan_wiki", ["documents": [["title": "Again", "goal": "Again"]]]); checks["automaticPlanFreezesAfterFirstAcceptedStructure"] = false } catch { checks["automaticPlanFreezesAfterFirstAcceptedStructure"] = true }
            let enPlan = tasks.task(automatic)!.wikiJob!.plan, enRoot = tasks.task(automatic)!.wikiJob!.root, enPaths = try enPlan.paths(root: enRoot)
            for doc in enPlan.documents! { try files.writeData(Data(("# " + doc.title + "\n\n" + original).utf8), to: files.resolve(enPaths[doc.title]!)) }
            tasks.update(automatic) { $0.status = .completed }
            let index = try AgentProjectIndex(workspace: workspace.path, storage: tasks.directory), folder = index.directory.appendingPathComponent("wiki"); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for (taskID, language, plan, pageRoot) in [(id, "zh", config.plan, root), (automatic, "en", enPlan, enRoot)] {
                let pagePaths = try plan.paths(root: pageRoot), hashes = try Dictionary(uniqueKeysWithValues: pagePaths.values.map { ($0, try files.fileHash(files.resolve($0), maximum: 256_000)) })
                var imported = AgentWikiManifest(taskID: taskID, revision: index.snapshot()!.revision, created: Date(), pages: hashes, sources: ["README.md"])
                imported.version = 2; imported.branch = branch; imported.language = language; imported.root = pageRoot; imported.plan = plan
                try JSONEncoder().encode(imported).write(to: folder.appendingPathComponent(AgentFiles.hash(Data((branch + "\n" + language).utf8)) + ".json"), options: .atomic)
            }
            let zh = try AgentWiki.view(store: tasks, taskID: owner, language: "zh"), en = try AgentWiki.view(store: tasks, taskID: owner, language: "en")
            checks["manualImportedLanguageViewsHaveSeparateRootsAndLogicalParents"] = zh.root != en.root && zh.pages.count == 2 && en.pages.count == 2 && zh.pages.first(where: { $0.path == second })?.parent == first && en.pages.contains { $0.parent == enPaths["Overview"] }
            do { _ = try await call(id, "read_file", ["path": enPaths["Overview"]!]); checks["otherLanguageReadsRejected"] = false } catch { checks["otherLanguageReadsRejected"] = true }
            func checkout(_ name: String) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", workspace.path, "checkout", "--quiet", name]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PetError("实际 Git 分支切换失败") } }
            try checkout("wiki-two")
            let otherBranch = try AgentWiki.view(store: tasks, taskID: owner, language: "en")
            do { try AgentWiki.checkScope(tasks.task(id)!, store: tasks); checks["branchChangeStopsOriginalJobAndHidesPublishedLanguage"] = false } catch { checks["branchChangeStopsOriginalJobAndHidesPublishedLanguage"] = otherBranch.pages.isEmpty }
            try checkout("wiki-one")
            checks["branchReturnRestoresSameManualImportedManifest"] = try AgentWiki.view(store: tasks, taskID: owner, language: "en").manifest?.taskID == automatic
            checks["legacyDocumentsRemainReadableAndGeneratedRootsHidden"] = try AgentWiki.view(store: tasks, taskID: owner, language: "legacy").pages.map(\.path) == [".bluefatfish/wiki/index.md"]
            try files.writeData(Data((config.text + "\n# 外部共享规划变更\n").utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            checks["persistedJobKeepsOriginalPlanAndConfigurationHash"] = tasks.task(id)?.wikiJob?.plan == config.plan && tasks.task(id)?.wikiJob?.configurationHash == AgentFiles.hash(compatible)
            try fm.removeItem(at: files.resolve(AgentWikiPlan.configurationPath))
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 规划前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: first) else { throw PetError("Wiki 窗口未打开") }
            records.enableWikiGeneration { language in try? write(["language": language, "modelsCalled": false], "wiki-plan-generate-selection.json") }
            control.prepareExtensionCheckWindow(taskID: owner, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": owner, "workspace": workspace.path, "checks": checks, "modelsCalled": false, "zhPaths": paths, "enPaths": enPaths, "compatibleHash": AgentFiles.hash(compatible)], "wiki-plan-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-plan-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-plan-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); try write(state, "native-wiki-plan-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-plan-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] {
                report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == hash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui
            }
            checks["compatibleConfigurationBytesUnchanged"] = try files.readData(files.resolve(AgentWikiPlan.compatiblePath)) == compatible
            checks["originalComposerDraftUnchanged"] = tasks.task(owner)?.draft == "保留的规划验收草稿"
            checks["noModelReceiptsOrFabricatedMessages"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty }
            try write(await records.markdownEditingReadback(), "native-wiki-plan-final.json"); report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "wiki-plan-report.json")
    }
}
