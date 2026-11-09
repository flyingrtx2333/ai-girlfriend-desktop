import AppKit

@MainActor extension AppDelegate {
    func runAgentRepoWikiOverviewCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual local Git repositories, source excerpts manually arranged as Wiki documents, real export/import, current branches, native task preparation and windows. No model-generated documents or assistant replies."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("Wiki 总览验收不调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var attempts = 0; runtime.modelRequestCheck = { attempts += 1; throw PetError("Wiki 总览验收禁止发送模型请求") }
            let fm = FileManager.default, alpha = output.appendingPathComponent("projects/alpha"), beta = output.appendingPathComponent("projects/beta"), gamma = output.appendingPathComponent("projects/gamma"), missing = output.appendingPathComponent("projects/disconnected"), held = output.appendingPathComponent("held-disconnected")
            let a = tasks.create(title: "阅读项目源码", workspace: alpha.path), b = tasks.create(title: "规划项目 Wiki", workspace: beta.path), none = tasks.create(title: "无工作区的对话")
            tasks.update(a) { $0.draft = "保留的 Alpha 草稿" }; tasks.update(b) { $0.draft = "保留的 Beta 草稿" }; tasks.update(none) { $0.draft = "保留的无项目草稿" }
            for path in [alpha, beta, gamma, missing] { try tasks.organization.register(path.path, mode: .coding) }
            try tasks.organization.register(alpha.path, mode: .general)
            try tasks.organization.rename(alpha.path, mode: .coding, name: "Alpha 源码", tasks: tasks.tasks); try tasks.organization.rename(beta.path, mode: .coding, name: "Beta 规划", tasks: tasks.tasks)
            try fm.moveItem(at: missing, to: held)
            let storage = tasks.directory
            func read(_ language: String = "zh") async throws -> [AgentRepoWikiSummary] {
                let projects = AgentRepoWikiOverview.projects(tasks)
                return try await Task.detached { try AgentRepoWikiOverview.read(projects, storage: storage, language: language) }.value
            }
            let originalIDs = Set(tasks.tasks.map(\.id)), originalSelection = tasks.selectedID
            let before = try await read()
            checks["workspaceWithoutTaskAppearsAndModesDoNotDuplicateProjects"] = before.count == 4 && Set(before.map(\.id)).count == 4 && before.contains { $0.project.workspace == gamma.path && $0.project.taskID == nil }
            checks["browsingDoesNotCreateTasksOrChangeSelection"] = Set(tasks.tasks.map(\.id)) == originalIDs && tasks.selectedID == originalSelection
            let old = before.first { $0.project.workspace == alpha.path }!
            checks["actualLegacySourceExcerptsAreNotInventedGeneration"] = old.pages == 2 && old.published == false && old.status == "未校验"
            checks["unavailableWorkspaceIsIsolatedFromOtherProjects"] = before.first { $0.project.workspace == missing.path }?.problem != nil && before.filter { $0.problem == nil }.count == 3
            let index = try AgentProjectIndex(workspace: alpha.path, storage: storage); _ = try await index.run(paths: nil)
            _ = try await AgentWiki.exportWiki(store: tasks, taskID: a, language: "zh")
            let imported = try await AgentWiki.previewWikiImport(store: tasks, taskID: a, language: "zh"); try await AgentWiki.importWiki(imported, store: tasks, taskID: a)
            let view = try AgentWiki.view(store: tasks, taskID: a, language: "zh"), rows = try await read(), published = rows.first { $0.project.workspace == alpha.path }!
            checks["realImportIsCountedAtItsActualPublicationTime"] = published.pages == 2 && published.published == true && published.updated == view.manifest?.created && view.manifest?.origin == "import"
            checks["overviewAndExistingWikiReaderUseTheSameStatus"] = try published.status == AgentWiki.status(store: tasks, taskID: a, language: "zh") && published.status == "待核对"
            checks["readingImportedKnowledgeDoesNotCreateGenerationTasks"] = !tasks.tasks.contains { $0.kind == "wiki" } && Set(tasks.tasks.map(\.id)) == originalIDs
            let english = try await read("en")
            checks["englishDoesNotReuseChinesePublicationOrPages"] = english.first { $0.project.workspace == alpha.path }.map { $0.pages == 0 && $0.published == false && $0.updated == nil && $0.status == "未生成" } == true
            func git(_ arguments: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", alpha.path] + arguments; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PetError("验收项目的 Git 操作失败") }
            }
            try git(["checkout", "--quiet", "overview-other"])
            let otherBranch = try await read()
            checks["actualBranchSwitchDoesNotReuseOtherBranchPublication"] = otherBranch.first { $0.project.workspace == alpha.path }.map { $0.branch == "refs/heads/overview-other" && $0.published == false } == true
            try git(["checkout", "--quiet", "main"])
            let returned = try await read()
            checks["returningBranchRetainsOriginalPublication"] = returned.first { $0.project.workspace == alpha.path }.map { $0.branch == "refs/heads/main" && $0.published == true && $0.updated == published.updated } == true
            let files = try AgentFiles(workspace: alpha.path), page = try files.resolve(view.root + "/index.md"), bytes = try files.readData(page)
            try files.writeData(bytes + Data("\n<!-- 实际外部编辑，用于核对总览刷新 -->\n".utf8), to: page)
            let edited = try await read()
            checks["actualDocumentEditChangesOverviewStatus"] = edited.first { $0.project.workspace == alpha.path }?.status == "已编辑"
            try files.writeData(bytes, to: page)
            let scope = try tasks.knowledgeCards.scope(tasks.task(a)!), pointer = scope.directory.deletingLastPathComponent().appendingPathComponent("wiki/" + AgentFiles.hash(Data((scope.branch + "\nzh").utf8)) + ".json"), pointerData = try Data(contentsOf: pointer)
            try pointerData.write(to: output.appendingPathComponent("held-wiki-pointer.json")); try Data("{".utf8).write(to: pointer, options: .atomic)
            let damaged = try await read()
            checks["corruptPublicationIsUnknownInsteadOfUnpublished"] = damaged.first { $0.project.workspace == alpha.path }.map { $0.problem != nil && $0.published == nil && $0.pages == nil } == true && damaged.first { $0.project.workspace == beta.path }?.published == false
            try pointerData.write(to: pointer, options: .atomic)
            let worktree = AgentRepoWikiProject(workspace: output.appendingPathComponent("projects/external-worktree").path, name: "需要连接的工作树", mode: .coding)
            let denied = try await Task.detached { try AgentRepoWikiOverview.read([worktree], storage: storage, language: "zh") }.value
            checks["externalGitMetadataIsNotSilentlyConnected"] = denied.first?.problem?.contains("Git 元数据") == true && denied.first?.published == nil
            let betaIndex = try AgentProjectIndex(workspace: beta.path, storage: storage), betaRevision = try await betaIndex.run(paths: nil).index.revision
            let pending = try AgentWiki.startPlanned(store: tasks, runtime: runtime, sourceID: b, language: "zh", revision: betaRevision, startImmediately: false)
            let pendingRows = AgentRepoWikiOverview.progress(try await read(), store: tasks, language: "zh")
            checks["realPreparedWikiIsPendingWithoutClaimingGeneration"] = pendingRows.first { $0.project.workspace == beta.path }?.status == "待开始" && tasks.task(pending)?.status == .ready && !runtime.isExecuting(pending) && attempts == 0
            let englishRows = AgentRepoWikiOverview.progress(try await read("en"), store: tasks, language: "en")
            checks["preparedChineseTaskDoesNotChangeEnglishStatus"] = englishRows.first { $0.project.workspace == beta.path }?.status == "未生成"
            let organizationFile = output.appendingPathComponent("profile/organization.json"), organizationBytes = try Data(contentsOf: organizationFile), indexBytes = try Data(contentsOf: storage.appendingPathComponent("index.json")), taskBytes = try Dictionary(uniqueKeysWithValues: tasks.tasks.map { ($0.id, try Data(contentsOf: storage.appendingPathComponent($0.id + ".json"))) })
            _ = try await read(); _ = try await read("en")
            checks["refreshReadsDoNotRewriteOrganizationIndexOrTaskFiles"] = try Data(contentsOf: organizationFile) == organizationBytes && Data(contentsOf: storage.appendingPathComponent("index.json")) == indexBytes && taskBytes.allSatisfy { (try? Data(contentsOf: storage.appendingPathComponent($0.key + ".json"))) == $0.value }
            checks["legacyAndImportedSourceExcerptBytesRemainIntact"] = try files.readData(page) == bytes && pointerData == Data(contentsOf: pointer)
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 总览原生检查未通过") }
            control.showAgentTask(none); control.show(tab: "chat"); control.prepareRepoWikiOverviewCheck()
            for _ in 0..<120 { if await control.repoWikiOverviewReadback()["loading"] as? Bool == false { break }; await wait(0.1) }
            let initial = await control.repoWikiOverviewReadback()
            checks["actualOverviewOpensFromTaskWithoutWorkspace"] = initial["total"] as? Int == 4 && initial["selectedTask"] as? String == none && initial["draft"] as? String == "保留的无项目草稿"
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 总览窗口未准备好") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "tasks": ["alpha": a, "beta": b, "none": none, "pendingWiki": pending], "projects": ["alpha": alpha.path, "beta": beta.path, "gamma": gamma.path, "missing": missing.path, "held": held.path], "manifest": ["root": view.root, "taskID": view.manifest!.taskID], "modelsCalled": false, "initial": initial], "repo-wiki-overview-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-repo-wiki-overview-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-repo-wiki-overview-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var value = await control.repoWikiOverviewReadback(); value["appPID"] = getpid(); try write(value, "native-repo-wiki-overview-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("repo-wiki-overview-ui-acceptance.json")), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = value["checks"] as? [String: Bool] { report["uiValidated"] = value["appPID"] as? Int == Int(getpid()) && value["binaryHash"] as? String == hash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = value }
            checks["allOriginalDraftsAndSelectedConversationRemain"] = tasks.task(a)?.draft == "保留的 Alpha 草稿" && tasks.task(b)?.draft == "保留的 Beta 草稿" && tasks.task(none)?.draft == "保留的无项目草稿" && tasks.selectedID == none
            checks["noModelAttemptsReceiptsAssistantRepliesOrStartedWiki"] = attempts == 0 && tasks.task(pending)?.status == .ready && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains { $0.role == "assistant" } }
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "repo-wiki-overview-report.json")
    }
}
