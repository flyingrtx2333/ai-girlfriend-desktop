import AppKit

@MainActor extension AppDelegate {
    struct HandoffFixture: Codable {
        struct Source: Codable {
            let origin: AgentWorktreeOrigin
            let localHead: String
            let localBranch: String
            let localIndex: String
            let sourceHead: String
            let sourceIndex: String
            let merge: Bool
        }
        let taskID: String
        let sources: [Source]
        let attachmentID: String
    }

    func prepareWorktreeHandoffFixtures(_ output: URL, multi: Bool) async throws -> HandoffFixture {
        ensureAgent()
        guard let tasks = agentStore else { throw PetError("工作树验收任务不可用") }
        let taskID: String
        if multi {
            let id = try await prepareWorkspaceWorktreeFixtures(output, tasks: tasks)
            let helper = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: tasks.task(id)?.workspace))
            let review = try await helper.prepareWorktreeCreation(branch: "acceptance/handoff")
            taskID = try await helper.createReviewedWorktree(review.hash).taskID
        } else {
            taskID = try await prepareWorktreeWorkspaceUI(output).childID
        }
        guard let task = tasks.task(taskID) else { throw PetError("缺少已创建的验收工作树") }
        let origins = try task.workspacePaths.map { path in
            guard let value = task.managedWorktreeOrigins.first(where: { $0.path == path }) else { throw PetError("缺少验收来源") }
            return value
        }
        func git(_ args: [String], at path: String) async throws -> String {
            try await workspaceWorktreeGit(args, root: URL(fileURLWithPath: path), output: output)
                .trimmingCharacters(in: .newlines)
        }
        func write(_ text: String, _ name: String, in root: String) throws {
            try Data((text + "\n").utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
        }
        func index(_ root: String) async throws -> String {
            let path = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root)
            return AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        var sources: [HandoffFixture.Source] = []
        for (i, origin) in origins.enumerated() {
            let local = origin.root, source = origin.path
            _ = try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--", "public.txt"], at: local)
            if i == 0 {
                try write("preserve local commit", "local-handoff.txt", in: local)
                var files = ["local-handoff.txt"]
                if FileManager.default.fileExists(atPath: local + "/notes.txt") { files.append("notes.txt") }
                _ = try await git(["add", "--"] + files, at: local)
                _ = try await git(["commit", "-m", "local handoff baseline"], at: local)
            }
            try write("worktree committed \(i)", "handoff-commit.txt", in: source)
            _ = try await git(["add", "--", "handoff-commit.txt"], at: source)
            _ = try await git(["commit", "--only", "-m", "worktree handoff commit \(i)", "--", "handoff-commit.txt"], at: source)
            try write("handoff staged \(i)", "public.txt", in: source)
            _ = try await git(["add", "--", "public.txt"], at: source)
            try write("handoff working \(i)", "public.txt", in: source)
            try Data([0, 255, UInt8(i)]).write(to: URL(fileURLWithPath: source).appendingPathComponent("handoff.bin"))
            try FileManager.default.createSymbolicLink(atPath: source + "/handoff-link", withDestinationPath: "public.txt")
            _ = try await git(["update-index", "--split-index"], at: source)
            sources.append(try await .init(origin: origin, localHead: git(["rev-parse", "HEAD"], at: local),
                                           localBranch: git(["symbolic-ref", "HEAD"], at: local), localIndex: index(local),
                                           sourceHead: git(["rev-parse", "HEAD"], at: source), sourceIndex: index(source), merge: i == 0))
        }
        tasks.update(taskID) {
            $0.title = "待移交的公开工作树"; $0.status = .completed
            $0.messages = [AgentMessage(role: "user", content: "核对公开工作树资料。"), AgentMessage(role: "assistant", content: "公开样例已准备。")]
            $0.draft = "移交后的本地草稿。"; $0.modelOverride = "deepseek-flash"
        }
        let attachment = try await AgentAttachments.importFile(URL(fileURLWithPath: origins[0].path).appendingPathComponent("public.txt"), store: tasks, taskID: taskID)
        tasks.selectedID = taskID
        control.showAgentTask(taskID); control.show(tab: "chat"); control.showAgentGit()
        let fixture = HandoffFixture(taskID: taskID, sources: sources, attachmentID: attachment.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: output.appendingPathComponent("worktree-handoff-fixtures.json"), options: .atomic)
        return fixture
    }

    func runWorktreeHandoffCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            let fixture = try await prepareWorktreeHandoffFixtures(output, multi: true)
            guard let tasks = agentStore, let runtime = agentRuntime, let initial = tasks.task(fixture.taskID) else {
                throw PetError("独立移交资料不可用")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("工作树移交不调用模型") }
            let record = tasks.directory.appendingPathComponent(fixture.taskID + ".json"), original = try Data(contentsOf: record)
            let handoff = AgentWorktreeHandoff(store: tasks, taskID: fixture.taskID)
            func git(_ args: [String], at path: String) async throws -> String {
                try await workspaceWorktreeGit(args, root: URL(fileURLWithPath: path), output: output).trimmingCharacters(in: .newlines)
            }
            func originalGit() async throws -> Bool {
                for item in fixture.sources {
                    let home = item.origin.root, child = item.origin.path
                    let localIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: home)
                    let sourceIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: child)
                    guard try AgentFiles.hash(Data(contentsOf: URL(fileURLWithPath: localIndex))) == item.localIndex,
                          try AgentFiles.hash(Data(contentsOf: URL(fileURLWithPath: sourceIndex))) == item.sourceIndex,
                          try await git(["rev-parse", "HEAD"], at: home) == item.localHead,
                          try await git(["rev-parse", "HEAD"], at: child) == item.sourceHead,
                          try await git(["status", "--porcelain"], at: home).isEmpty else { return false }
                }
                return true
            }
            let first = try await handoff.prepare()
            checks["previewIncludesCommittedStagedAndWorkingContentForEachSource"] = first.plans.count == 2 && first.plans.enumerated().allSatisfy { i, plan in
                plan.commits.contains("worktree handoff commit \(i)") && plan.patches[0].contains("handoff-commit.txt")
                    && plan.patches[1].contains("+handoff staged \(i)") && plan.patches[2].contains("+handoff working \(i)")
                    && (plan.source.appliedHead == nil) == fixture.sources[i].merge
            }
            checks["previewPreservesAllLocalBranchesIndexesAndSourceTasks"] = try await originalGit() && Data(contentsOf: record) == original
            let secondary = fixture.sources[1], working = URL(fileURLWithPath: secondary.origin.path + "/public.txt")
            let previous = try Data(contentsOf: working)
            try Data("后续工作树写入\n".utf8).write(to: working)
            do { _ = try await handoff.apply(first); checks["changedWorkingFileRejectsOldReview"] = false }
            catch { checks["changedWorkingFileRejectsOldReview"] = error.localizedDescription.contains("重新审阅") }
            try previous.write(to: working)
            handoff.discard(first)
            let dirty = URL(fileURLWithPath: secondary.origin.root + "/pending.txt")
            try Data("本地未提交内容\n".utf8).write(to: dirty)
            do { _ = try await handoff.prepare(); checks["dirtySecondaryBlocksEntireReview"] = false }
            catch { checks["dirtySecondaryBlocksEntireReview"] = error.localizedDescription.contains("本地工作区有改动") }
            try FileManager.default.removeItem(at: dirty)
            let blocked = try await handoff.prepare()
            let refLock = URL(fileURLWithPath: secondary.origin.metadata).appendingPathComponent(secondary.localBranch + ".lock")
            try Data("fixture in-progress Git reference update\n".utf8).write(to: refLock, options: .withoutOverwriting)
            do { _ = try await handoff.apply(blocked); checks["referenceFailureRollsBackAlreadyAppliedSource"] = false }
            catch {
                checks["referenceFailureRollsBackAlreadyAppliedSource"] = try await originalGit()
                    && Data(contentsOf: record) == original && error.localizedDescription.contains("已恢复本次写入")
            }
            try FileManager.default.removeItem(at: refLock)
            handoff.discard(blocked)
            let ready = try await handoff.prepare()
            let id = try await handoff.apply(ready)
            handoff.discard(ready)
            guard let child = tasks.task(id) else { throw PetError("本地延续任务未保存") }
            var parentsCorrect = true, workCorrect = true, originalSources = true
            for (i, item) in fixture.sources.enumerated() {
                let home = item.origin.root, source = item.origin.path
                let ref = try await git(["symbolic-ref", "HEAD"], at: home)
                let head = try await git(["rev-parse", "HEAD"], at: home)
                let ancestry = try await git(["rev-list", "--parents", "-n", "1", head], at: home)
                parentsCorrect = parentsCorrect && ref == item.localBranch &&
                    (item.merge ? ancestry == "\(head) \(item.localHead) \(item.sourceHead)" : head == item.sourceHead)
                let staged = try await git(["show", ":public.txt"], at: home)
                let state = try await git(["status", "--porcelain"], at: home)
                workCorrect = try workCorrect && staged == "handoff staged \(i)" && state.contains("MM public.txt") && state.contains("?? handoff.bin")
                    && String(contentsOfFile: home + "/public.txt", encoding: .utf8) == "handoff working \(i)\n"
                    && String(contentsOfFile: home + "/handoff-commit.txt", encoding: .utf8) == "worktree committed \(i)\n"
                    && Data(contentsOf: URL(fileURLWithPath: home + "/handoff.bin")) == Data([0, 255, UInt8(i)])
                    && FileManager.default.destinationOfSymbolicLink(atPath: home + "/handoff-link") == "public.txt"
                    && FileManager.default.fileExists(atPath: home + "/local-only.txt")
                let sourceHead = try await git(["rev-parse", "HEAD"], at: source)
                let sourceIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: source)
                originalSources = try originalSources && sourceHead == item.sourceHead && AgentFiles.hash(Data(contentsOf: URL(fileURLWithPath: sourceIndex))) == item.sourceIndex
            }
            checks["historyRetainsMergeParentsAndFastForwardsOtherSource"] = parentsCorrect
            checks["targetRetainsSeparateStagedWorkingBinaryAndSymlinkChanges"] = workCorrect
            checks["originalWorktreeAndConversationAreUntouched"] = try originalSources && Data(contentsOf: record) == original && tasks.task(fixture.taskID)?.messages.count == initial.messages.count
            checks["continuationHasOriginalDraftModelAndAllLocalSources"] = child.parentID == fixture.taskID && child.worktreeOrigin == nil
                && child.workspacePaths == fixture.sources.map(\.origin.root) && child.modelOverride == initial.modelOverride
                && child.draft == initial.draft && child.draftAttachmentIDs == [fixture.attachmentID]
            let localAttachment = try AgentAttachments.source(store: tasks, taskID: id, id: fixture.attachmentID)
            let sourceAttachment = try AgentAttachments.source(store: tasks, taskID: fixture.taskID, id: fixture.attachmentID)
            checks["continuationReadsOwnAttachment"] = try localAttachment != sourceAttachment && Data(contentsOf: localAttachment) == Data(contentsOf: sourceAttachment)
            do { _ = try await handoff.apply(ready); checks["confirmedReviewCannotRunAgain"] = false }
            catch { checks["confirmedReviewCannotRunAgain"] = error.localizedDescription.contains("已处理") }
            let history = try tasks.backupDirectory(fixture.taskID).appendingPathComponent("worktree-handoff")
            let directories = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            guard let transaction = directories.first(where: {
                (try? String(contentsOf: $0.appendingPathComponent("outcome"), encoding: .utf8))?.hasPrefix("completed\n" + id + "\n") == true
            }) else { throw PetError("缺少已完成的移交记录") }
            let outcome = transaction.appendingPathComponent("outcome")
            try FileManager.default.moveItem(at: outcome, to: transaction.appendingPathComponent("verified-outcome"))
            let gitDirs = fixture.sources.map { URL(fileURLWithPath: $0.origin.metadata) }
            let owned = gitDirs[0].appendingPathComponent("bluefatfish-handoff-" + transaction.lastPathComponent + ".lock")
            let ownedIndex = gitDirs[0].appendingPathComponent("index.lock"), foreign = gitDirs[1].appendingPathComponent("index.lock")
            let foreignBytes = Data("Git lock owned by another operation\n".utf8)
            try Data().write(to: owned, options: .withoutOverwriting)
            try FileManager.default.linkItem(at: owned, to: ownedIndex)
            try foreignBytes.write(to: foreign, options: .withoutOverwriting)
            let localRecord = tasks.directory.appendingPathComponent(id + ".json")
            let savedTask = try Data(contentsOf: localRecord)
            func localHeads() async throws -> [String] {
                var result: [String] = []
                for item in fixture.sources { result.append(try await git(["rev-parse", "HEAD"], at: item.origin.root)) }
                return result
            }
            let heads = try await localHeads()
            let reloadedTasks = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [],
                                            extensionHome: output.appendingPathComponent("shared-home", isDirectory: true))
            let reopened = AgentWorktreeHandoff(store: reloadedTasks, taskID: fixture.taskID)
            guard let pending = try reopened.pendingRecovery(), pending.published else { throw PetError("落盘的本地任务未被识别") }
            do { _ = try reloadedTasks.prepareDeletion([fixture.taskID]); checks["unresolvedHandoffProtectsItsSourceTask"] = false }
            catch {
                report["sourceDeletionGuard"] = error.localizedDescription
                checks["unresolvedHandoffProtectsItsSourceTask"] = error.localizedDescription.contains("中断的工作树移交")
            }
            let recovered = try await reopened.recover(pending)
            let afterHeads = try await localHeads()
            checks["publishedContinuationIsReusedWithoutChangingBranchesOrTask"] = try recovered == id
                && heads == afterHeads && Data(contentsOf: localRecord) == savedTask && reopened.pendingRecovery() == nil
            checks["publishedRecoveryClearsOnlyItsOwnGitLock"] = try !FileManager.default.fileExists(atPath: owned.path)
                && !FileManager.default.fileExists(atPath: ownedIndex.path) && Data(contentsOf: foreign) == foreignBytes
            try FileManager.default.removeItem(at: foreign)
            checks["noModelRequests"] = requests == 0
            report["localTaskID"] = id
        } catch { report["error"] = error.localizedDescription }
        report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["checks"] = checks; report["appPID"] = getpid(); report["modelRequests"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("worktree-handoff-report.json"), options: .atomic)
    }
}
