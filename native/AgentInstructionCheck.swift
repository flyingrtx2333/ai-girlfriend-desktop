import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentInstructionCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        func waitUntil(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while !test() && Date() < end { await wait(0.03) }; return test() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("指令原生检查禁止模型请求") }
            let project = output.appendingPathComponent("real project"), source = project.appendingPathComponent("src/deep/source.swift"), original = try Data(contentsOf: source)
            let id = tasks.create(title: "实际嵌套指令与引用", workspace: project.path, mode: .ask, workMode: .general)
            let other = tasks.create(title: "指令跨任务隔离", workspace: project.path, mode: .ask, workMode: .general)
            let global = tasks.create(title: "无工作区用户指令", mode: .ask, workMode: .general)
            let service = tasks.instructions
            func task(_ id: String) -> AgentTaskRecord { tasks.task(id)! }
            func context(_ id: String) throws -> String { try runtime.systemContext(task(id)) }
            func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
            let userBefore = try AgentMemory.snapshot(.userInstructions, store: tasks, taskID: global)
            _ = try AgentMemory.save(.userInstructions, content: "USER_INSTRUCTIONS_327\n", expectedHash: userBefore.hash, store: tasks, taskID: global)
            let initial = try context(id), globalContext = try context(global)
            checks["userAndQoderInstructionsWorkWithoutWorkspace"] = globalContext.contains("USER_INSTRUCTIONS_327") && globalContext.contains("QODER_INSTRUCTIONS_428") && globalContext.contains("USER_RELATIVE_IMPORT_529") && globalContext.contains("USER_HOME_IMPORT_630") && !globalContext.contains("ROOT_INSTRUCTIONS_731")
            checks["rootAndLocalInstructionsLoadAtStartup"] = initial.contains("ROOT_INSTRUCTIONS_731") && initial.contains("LOCAL_INSTRUCTIONS_832")
            checks["recursiveRelativeImportsLoadOnceAndCyclesTerminate"] = service.report(task(id)).sources.filter { $0.path.hasSuffix("docs/guide.md") }.count == 1 && initial.contains("PROJECT_IMPORT_933") && initial.contains("CYCLE_IMPORT_134")
            checks["unreadNestedInstructionsAreNotPreloaded"] = !initial.contains("NESTED_INSTRUCTIONS_235") && !initial.contains("DEEP_LOCAL_336") && !initial.contains("NESTED_IMPORT_437")
            checks["markdownCodeEmailsAndEscapesAreNotImports"] = AgentInstructions.imports("See @README.md. `@inline.md`\n```md\n@fenced.md\n```\n~~~\n@tilde.md\n~~~\n    @indented.md\n\\@escaped.md name@example.com\nUse @\"with space.md\" and ``@code.md``.") == ["README.md", "with space.md"] && AgentInstructions.imports("\u{FEFF}@README.md\r\n") == ["README.md"]
            let tools = AgentTools(store: tasks, taskID: id), otherTools = AgentTools(store: tasks, taskID: other)
            let beforeFailure = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json"))
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/deep/missing.swift"])); checks["failedReadDoesNotDiscoverInstructions"] = false }
            catch { checks["failedReadDoesNotDiscoverInstructions"] = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json")) == beforeFailure }
            do { _ = try await otherTools.execute(call("read_file", ["path": "src/linked.swift"])); checks["outsideSymlinkReadCannotDiscoverInstructions"] = false }
            catch { checks["outsideSymlinkReadCannotDiscoverInstructions"] = try Data(contentsOf: tasks.directory.appendingPathComponent(other + ".json")) == beforeFailure }
            let read = try await tools.execute(call("read_file", ["path": "src/deep/source.swift", "limit": 3]))
            let loaded = try context(id)
            checks["actualFileReadDiscoversAncestorsAndAcknowledgesNewInstructions"] = !read.failed && read.text.contains("已发现该文件目录的项目指令") && loaded.contains("NESTED_INSTRUCTIONS_235") && loaded.contains("DEEP_LOCAL_336") && loaded.contains("NESTED_IMPORT_437") && task(id).instructionDirectories?.map(\.path) == ["src", "src/deep"]
            checks["discoveryIsTaskBoundAndDoesNotRewriteFilesOrMessages"] = try !context(other).contains("NESTED_INSTRUCTIONS_235") && Data(contentsOf: source) == original && task(id).messages.isEmpty
            let writerID = tasks.create(title: "写入不冒充已读指令", workspace: project.path, mode: .agent, workMode: .general)
            tasks.update(writerID) { $0.permission = .automatic }
            _ = try await AgentTools(store: tasks, taskID: writerID).execute(call("write_file", ["path": "src/generated.txt", "content": "Actual generated file\n"]))
            checks["writeDoesNotPretendToReadNestedInstructions"] = task(writerID).instructionDirectories == nil
            let guide = project.appendingPathComponent("docs/guide.md"), guideOriginal = try Data(contentsOf: guide)
            try (String(decoding: guideOriginal, as: UTF8.self) + "\nDYNAMIC_IMPORTED_CHANGE_538\n").write(to: guide, atomically: true, encoding: .utf8)
            let editedGuideHash = AgentFiles.hash(try Data(contentsOf: guide))
            checks["nextTurnReloadsEditedImportedSourceWithFreshHash"] = try context(id).contains("DYNAMIC_IMPORTED_CHANGE_538") && service.report(task(id)).sources.contains { $0.path == guide.path && $0.sha256 == editedGuideHash }
            try guideOriginal.write(to: guide, options: .atomic)
            let rootFile = project.appendingPathComponent("AGENTS.md"), rootOriginal = try Data(contentsOf: rootFile), external = output.appendingPathComponent("external instructions.md")
            try (String(decoding: rootOriginal, as: UTF8.self) + "\n@\"../external instructions.md\"\n").write(to: rootFile, atomically: true, encoding: .utf8)
            let blocked = service.report(task(id)); var rejected = false
            do { _ = try context(id) } catch { rejected = error.localizedDescription.contains("有效指令") }
            checks["externalImportIsVisibleButUnreadUntilExplicitAllowance"] = rejected && blocked.issues.contains { $0.needsPermission && $0.path == external.path } && !blocked.preview.contains("EXTERNAL_ALLOWED_639")
            let effective = try AgentMemory.snapshot(.effectiveInstructions, store: tasks, taskID: id)
            checks["effectiveInstructionsAreReadonlyAndShowSourceAndPendingPath"] = effective.content.contains("项目 · AGENTS.md") && effective.content.contains(external.path) && effective.content.contains("ROOT_INSTRUCTIONS_731") && !effective.content.contains("sha256=")
            do { _ = try AgentMemory.save(.effectiveInstructions, content: "replace", expectedHash: effective.hash, store: tasks, taskID: id); checks["effectiveViewCannotReplaceSource"] = false }
            catch { checks["effectiveViewCannotReplaceSource"] = try Data(contentsOf: rootFile) != Data("replace".utf8) }
            try service.allow(external, store: tasks, taskID: id)
            checks["explicitFileAllowanceLoadsOnlyRequestedInstructionFile"] = try context(id).contains("EXTERNAL_ALLOWED_639") && !service.report(task(other)).preview.contains("EXTERNAL_ALLOWED_639")
            do { _ = try await tools.execute(call("read_file", ["path": external.path])); checks["instructionAllowanceDoesNotGrantFileToolAccess"] = false }
            catch { checks["instructionAllowanceDoesNotGrantFileToolAccess"] = task(id).mode == .ask && task(id).permission == .workspace }
            var moved = task(id); moved.workspace = output.appendingPathComponent("other project").path
            checks["workspaceChangeCannotReuseNestedDiscoveryOrExternalAllowance"] = !service.report(moved).text.contains("EXTERNAL_ALLOWED_639") && !service.report(moved).text.contains("NESTED_INSTRUCTIONS_235")
            let data = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")), decoded = try JSONDecoder().decode(AgentTaskRecord.self, from: data)
            checks["actualStoredTaskRetainsDiscoveryAndExactWorkspaceFileAllowance"] = decoded.instructionDirectories == task(id).instructionDirectories && decoded.instructionGrants == [AgentInstructionGrant(workspace: project.path, path: external.path)] && service.report(decoded).text.contains("EXTERNAL_ALLOWED_639")
            try service.revoke(external.path, store: tasks, taskID: id)
            checks["revocationImmediatelyRemovesExternalBodyAndPreservesSource"] = try !service.report(task(id)).preview.contains("EXTERNAL_ALLOWED_639") && service.report(task(id)).issues.contains(where: \.needsPermission) && Data(contentsOf: external) == Data("EXTERNAL_ALLOWED_639\n".utf8)
            let slow = tasks.create(title: "撤销指令实际取消", workspace: project.path, mode: .agent, workMode: .general)
            try service.allow(external, store: tasks, taskID: slow)
            guard runtime.submit("核对本任务的命令取消，不发送模型请求。", taskID: slow, startImmediately: false) else { throw PetError(runtime.submissionError ?? "命令取消输入未保存") }
            let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pending = try call("run_command", ["command": "'" + node.replacingOccurrences(of: "'", with: "'\\''") + "' slow.cjs", "timeout_seconds": 40, "network": false])
            tasks.update(slow) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(slow)
            let pidFile = project.appendingPathComponent("slow-pids.json")
            guard await waitUntil({ FileManager.default.fileExists(atPath: pidFile.path) && runtime.isRunning(slow) }), let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as? [String: Int], let parentProcess = pids["pid"], let childProcess = pids["child"] else { throw PetError("实际指令撤销进程尚未启动") }
            checks["allowedInstructionTaskOwnsActualLiveParentAndChild"] = kill(pid_t(parentProcess), 0) == 0 && kill(pid_t(childProcess), 0) == 0
            try service.revoke(external.path, store: tasks, taskID: slow)
            checks["revocationCancelsActualTaskAndBothProcesses"] = await waitUntil { !runtime.isRunning(slow) && kill(pid_t(parentProcess), 0) != 0 && kill(pid_t(childProcess), 0) != 0 }
            report["actualCancelledPIDs"] = [parentProcess, childProcess]
            try rootOriginal.write(to: rootFile, options: .atomic)
            let child = output.appendingPathComponent("ancestor repo/packages/app"), ancestorID = tasks.create(title: "仓库上级指令允许", workspace: child.path, mode: .ask, workMode: .general)
            let parent = output.appendingPathComponent("ancestor repo/AGENTS.md"), parentReport = service.report(task(ancestorID))
            checks["startupFindsRepoAncestorsButStopsAtGitBoundary"] = parentReport.issues.contains { $0.path == parent.path && $0.needsPermission } && parentReport.text.contains("CHILD_ROOT_740") && !parentReport.preview.contains("OUTSIDE_GIT_841") && !parentReport.text.contains("REPO_PARENT_942")
            try service.allow(parent, store: tasks, taskID: ancestorID)
            let parentContext = try context(ancestorID)
            checks["allowedRepoAncestorLoadsBeforeChosenSubdirectory"] = parentContext.range(of: "REPO_PARENT_942").map { parent in parentContext.range(of: "CHILD_ROOT_740").map { parent.lowerBound < $0.lowerBound } ?? false } == true
            let bad = tasks.create(title: "损坏与过深指令", workspace: output.appendingPathComponent("invalid project").path, mode: .ask, workMode: .general)
            checks["invalidUTF8FailsClosedWithoutSubstituteInstructions"] = service.report(task(bad)).issues.contains { $0.message.contains("UTF-8") }
            let deep = tasks.create(title: "引用深度限制", workspace: output.appendingPathComponent("deep project").path, mode: .ask, workMode: .general)
            checks["actualRecursiveFilesRespectDepthLimit"] = service.report(task(deep)).issues.contains { $0.message.contains("8层") }
            let sensitive = tasks.create(title: "敏感引用拒绝", workspace: output.appendingPathComponent("sensitive project").path, mode: .ask, workMode: .general)
            checks["credentialFileCannotBecomeInstructionImport"] = service.report(task(sensitive)).issues.contains { $0.message.contains("凭据") } && !service.report(task(sensitive)).preview.contains("NEVER_LOAD_ENV_143")
            let local = try AgentMemory.snapshot(.localInstructions, store: tasks, taskID: id)
            _ = try AgentMemory.save(.localInstructions, content: local.content + "\nSAVED_LOCAL_244\n", expectedHash: local.hash, store: tasks, taskID: id)
            do { _ = try AgentMemory.save(.localInstructions, content: "stale", expectedHash: local.hash, store: tasks, taskID: id); checks["localInstructionEditorPreservesConcurrentFileChange"] = false }
            catch { checks["localInstructionEditorPreservesConcurrentFileChange"] = try context(id).contains("SAVED_LOCAL_244") }
            checks["noModelReceiptsOrSyntheticAssistantReplies"] = tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty && tasks.task($0.id)?.messages.contains(where: \.isReply) != true }
            report["checkedTaskID"] = id; report["uiTaskID"] = other; report["sourceHash"] = AgentFiles.hash(original); report["initialContext"] = initial; report["effectiveContext"] = try context(id)
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(8); while agentRuntime?.isWorking == true && Date() < end { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["scope"] = "Actual user/project/nested instruction files, recursive imports, successful native file reads, exact external-file allowances and revocation, workspace isolation and stored task records. No external model requests; model instruction following and window behavior are not claimed."
        if let file = Bundle.main.executableURL, let bytes = try? Data(contentsOf: file) { report["binaryHash"] = AgentFiles.hash(bytes) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("instruction-result.json"), options: .atomic)
    }
}
