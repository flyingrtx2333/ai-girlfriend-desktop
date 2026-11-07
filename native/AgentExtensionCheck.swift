import AppKit

@MainActor extension AppDelegate {
    func runAgentExtensionCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--plugin-mcp-check") { await runAgentPluginMCPCheck(output); return }
        if CommandLine.arguments.contains("--plugin-check") { await runAgentPluginCheck(output); return }
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let library = tasks.extensions, workspace = output.appendingPathComponent("workspace"), id = tasks.create(title: "实际素材清单", workspace: workspace.path)
            let scratch = try tasks.backupDirectory(id).deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let marker = library.profile.appendingPathComponent("extension-private-marker.txt")
            try Data("public isolation marker".utf8).write(to: marker)
            let denied = try await AgentCommand().run(command: "/bin/cat " + AgentGit.quote(marker.path), workspace: output, scratch: scratch, network: false, timeout: 5, readOnly: true, protectedData: library.profile)
            checks["kernelCanonicalPrivateDataBoundaryRejectsAlias"] = denied.failed && denied.stdout?.contains("public isolation marker") != true
            let probe = scratch.appendingPathComponent("probe.txt")
            let permitted = try await AgentCommand().run(command: "printf scratch-ok > " + AgentGit.quote(probe.path) + " && /bin/cat " + AgentGit.quote(probe.path), workspace: output, scratch: scratch, network: false, timeout: 5, readOnly: true, protectedData: library.profile)
            checks["canonicalScratchCarveoutStillAllowsTaskFiles"] = !permitted.failed && permitted.stdout == "scratch-ok"
            phase("native-import")
            let skill = try await library.importItem(output.appendingPathComponent("asset-inventory.skill"), kind: .skill, project: false, workspace: workspace.path)
            checks["actualSkillArchiveImportsDefinitionAndScript"] = FileManager.default.fileExists(atPath: skill.root.appendingPathComponent("scripts/inventory.py").path) && skill.name == "asset-inventory"
            do { _ = try await library.importItem(output.appendingPathComponent("unsafe.zip"), kind: .skill, project: false, workspace: workspace.path); checks["archiveTraversalRejectedBeforePublication"] = false }
            catch { checks["archiveTraversalRejectedBeforePublication"] = !FileManager.default.fileExists(atPath: output.appendingPathComponent("escaped-extension.txt").path) }
            let command = try library.create(.command, name: "audit:handoff", text: "---\nname: display-name-does-not-route\ndescription: 根据真实执行记录生成交接。\n---\n\n根据本任务真实工具结果输出三个标题：结果、核对、未完成。结果包含 manifest.json，核对包含实际文件数量和任意文件 SHA256 的前十二位，不编造未执行的操作。\n\n$ARGUMENTS\n", project: false, workspace: workspace.path)
            checks["commandRoutingUsesRelativeFilePath"] = command.name == "audit:handoff" && command.file.lastPathComponent == "handoff.md" && command.file.deletingLastPathComponent().lastPathComponent == "audit"
            let expanded = try library.expand(AgentMessage(role: "user", content: "/audit:handoff 给下一位同事"), store: tasks, taskID: id)
            checks["commandPreservesOriginalAndExpandsArguments"] = expanded.content == "/audit:handoff 给下一位同事" && expanded.extensionInstructions?.contains("给下一位同事") == true && expanded.extensionInstructions?.contains("$ARGUMENTS") == false && expanded.extensionReferences?.first?.sha256 == command.sha256
            let original = try library.document(command).0
            let modified = original + "\n外部更新\n"; try Data(modified.utf8).write(to: command.file, options: .atomic)
            do { _ = try library.save(command, text: original + "changed", expectedHash: command.sha256, workspace: workspace.path); checks["editorConflictPreservesExternalChange"] = false }
            catch { checks["editorConflictPreservesExternalChange"] = try String(contentsOf: command.file, encoding: .utf8) == modified }
            try Data(original.utf8).write(to: command.file, options: .atomic)
            try library.setEnabled(command, enabled: false, workspace: workspace.path)
            let reopened = AgentExtensions(profile: library.profile, sharedHome: library.sharedHome)
            checks["disableSurvivesReloadAndBlocksInvocation"] = try reopened.item(command.id, workspace: workspace.path, enabled: false).enabled == false
            do { _ = try library.expand(AgentMessage(role: "user", content: "/audit:handoff"), store: tasks, taskID: id); checks["disabledCommandCannotExpand"] = false } catch { checks["disabledCommandCannotExpand"] = true }
            try library.setEnabled(command, enabled: true, workspace: workspace.path)
            let local = try library.create(.skill, name: "project-only", text: "---\nname: project-only\ndescription: 项目范围检查\n---\n\n仅用于当前项目。\n", project: true, workspace: workspace.path)
            let otherWorkspace = output.appendingPathComponent("other-project", isDirectory: true); try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
            let other = tasks.create(title: "隔离项目", workspace: otherWorkspace.path, mode: .ask)
            if let home = library.sharedHome {
                let shared = home.appendingPathComponent(".agents/skills/shared-priority", isDirectory: true)
                try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
                try Data("---\nname: shared-priority\ndescription: shared source\n---\n\n共享工作流。\n".utf8).write(to: shared.appendingPathComponent("SKILL.md"))
                let managed = try AgentFiles(workspace: library.profile.path)
                try managed.writeData(Data("---\nname: shared-priority\ndescription: managed source\n---\n\n当前用户管理的工作流。\n".utf8), to: managed.resolve("extensions/skills/shared-priority/SKILL.md"))
                let discovered = try library.catalog(workspace: workspace.path).filter { $0.kind == .skill && $0.name == "shared-priority" }
                checks["managedUserSkillWinsSharedDuplicate"] = discovered.count == 1 && discovered.first?.description == "managed source"
            }
            checks["projectExtensionDoesNotCrossWorkspace"] = try library.catalog(workspace: workspace.path).contains(where: { $0.id == local.id }) && !library.catalog(workspace: otherWorkspace.path).contains(where: { $0.id == local.id })
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("read_skill", ["id": local.id])); checks["foreignProjectSkillCannotActivate"] = false } catch { checks["foreignProjectSkillCannotActivate"] = true }
            let manual = try library.create(.skill, name: "manual-only", text: "---\nname: manual-only\ndescription: 手动检查\ndisable-model-invocation: true\n---\n\n只在用户手动选择后执行。\n", project: false, workspace: workspace.path)
            let wiki = tasks.create(title: "限定来源的 Wiki", workspace: workspace.path)
            tasks.update(wiki) { $0.kind = "wiki" }
            do { _ = try library.expand(AgentMessage(role: "user", content: "/skill:manual-only"), store: tasks, taskID: wiki); checks["wikiDoesNotLoadUnindexedExtensions"] = false } catch { checks["wikiDoesNotLoadUnindexedExtensions"] = true }
            let tools = AgentTools(store: tasks, taskID: id)
            let listed = try await tools.execute(call("list_skills", [:]))
            checks["manualOnlySkillHiddenFromAutomaticDiscovery"] = !listed.text.contains(manual.name)
            do { _ = try await tools.execute(call("read_skill", ["id": manual.id])); checks["manualOnlySkillRejectsAutomaticActivation"] = false } catch { checks["manualOnlySkillRejectsAutomaticActivation"] = true }
            let manualMessage = try library.expand(AgentMessage(role: "user", content: "/skill:manual-only 核对本次工作"), store: tasks, taskID: other)
            checks["explicitSkillCarriesVersionAndTaskOwnedSnapshot"] = manualMessage.extensionReferences?.first?.snapshot?.contains(other) == true && manualMessage.extensionInstructions?.contains("只在用户手动选择后执行") == true
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("read_skill_resource", ["id": manual.id, "path": "SKILL.md"])); checks["unsentSkillSelectionIsNotActive"] = false } catch { checks["unsentSkillSelectionIsNotActive"] = true }
            tasks.update(other) { $0.messages.append(manualMessage); $0.activateExtensions(manualMessage); $0.contextSummary = "已整理的原始要求"; $0.contextThroughID = manualMessage.id }
            checks["explicitSkillSurvivesContextCompaction"] = AgentContext.window(tasks.task(other)!).contains { $0.extensionInstructions?.contains("只在用户手动选择后执行") == true }
            let resource = try await AgentTools(store: tasks, taskID: other).execute(call("read_skill_resource", ["id": manual.id, "path": "SKILL.md"]))
            checks["activeSkillResourceReadableWithoutTerminal"] = resource.text.contains("只在用户手动选择后执行")
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("read_skill_resource", ["id": manual.id, "path": "../../settings.json"])); checks["resourcePathCannotEscapeSnapshot"] = false } catch { checks["resourcePathCannotEscapeSnapshot"] = true }
            do { _ = try AgentTools(store: tasks, taskID: other).approvalReason(for: call("run_command", ["command": "true"])); checks["skillDoesNotBroadenAskMode"] = false } catch { checks["skillDoesNotBroadenAskMode"] = true }
            let fork = tasks.fork(other)
            if let fork, let reference = tasks.task(fork)?.activeSkills?.first, let copy = reference.snapshot, let originalPath = manualMessage.extensionReferences?.first?.snapshot {
                let copied = try Data(contentsOf: URL(fileURLWithPath: copy).appendingPathComponent("SKILL.md")), original = try Data(contentsOf: URL(fileURLWithPath: originalPath).appendingPathComponent("SKILL.md"))
                checks["forkCopiesAndRemapsSkillSnapshot"] = copy != originalPath && copy.contains(fork) && copied == original
                checks["forkKeepsOriginalUserText"] = tasks.task(fork)?.messages.first?.content == manualMessage.content && tasks.task(fork)?.messages.first?.extensionInstructions?.contains(copy) == true
            } else { checks["forkCopiesAndRemapsSkillSnapshot"] = false }
            _ = try await AgentTools(store: tasks, taskID: other).execute(call("unload_skill", ["id": manual.id]))
            checks["unloadRemovesActiveInstructionsKeepsHistory"] = tasks.task(other)?.activeSkills?.isEmpty == true && tasks.task(other)?.messages.first?.extensionInstructions != nil && !AgentContext.window(tasks.task(other)!).contains { $0.extensionInstructions != nil }
            let manager = AgentExtensionWindow(store: tasks, taskID: id); manager.onInsert = { _ in }
            checks.merge(manager.checkLayout(output)) { _, latest in latest }; manager.close()
            checks.merge(try await control.checkExtensionComposer(output, taskID: id, item: command)) { _, latest in latest }
            if CommandLine.arguments.contains("--live-agent") {
                phase("real-model-skill")
                let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                tasks.update(id) { $0.permission = .review; $0.activeSkills = nil }
                defer { for task in tasks.tasks where runtime.isRunning(task.id) || task.status == .waiting { runtime.cancel(task.id) } }
                runtime.submit("在已安装的 Skills 中查找适合素材清单的流程，按照它的说明，为当前项目实际 assets 目录生成 manifest.json。使用已提供的流程与脚本，完成后核对真实输出并简短汇报；不改动任何输入素材，不联网。", taskID: id)
                var approvals = 0; let deadline = Date().addingTimeInterval(180)
                while Date() < deadline, let task = tasks.task(id), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let pending = task.pendingCalls.first {
                        guard pending.name == "run_command", let command = pending.object["command"] as? String, command.contains("inventory.py"), command.contains("manifest.json"), approvals < 2 else { throw PetError("Skill 验收提出了预期外动作") }
                        approvals += 1; runtime.decide(taskID: id, callID: pending.id, decision: "allow")
                    }; await wait(0.1)
                }
                guard let task = tasks.task(id) else { throw PetError("真实 Skill 任务丢失") }
                checks["realModelDiscoversAndLoadsInstalledSkill"] = task.events.contains { $0.title == "list_skills" && $0.status == "completed" } && task.events.contains { $0.title == "read_skill" && $0.status == "completed" }
                checks["realModelReadsAndRunsActualSkillResource"] = task.events.contains { $0.title == "read_skill_resource" && $0.status == "completed" } && task.events.contains { $0.title == "run_command" && $0.status == "completed" } && approvals > 0
                let manifest = workspace.appendingPathComponent("manifest.json")
                checks["realSkillTaskCompletedWithActualOutput"] = task.status == .completed && FileManager.default.fileExists(atPath: manifest.path)
                let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("independent-expected.json"))) as? [String: Any]
                let files = expected?["files"] as? [[String: Any]] ?? []
                checks["actualAssetInputsUnchanged"] = try files.allSatisfy { row in guard let name = row["name"] as? String, let hash = row["sha256"] as? String else { return false }; return try AgentFiles.hash(Data(contentsOf: workspace.appendingPathComponent("assets/" + name))) == hash }
                report["live"] = ["model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "skillStatus": task.status.rawValue, "skillResult": task.summary, "approvalCount": approvals, "events": task.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] }]
                guard task.status == .completed else { throw PetError(task.events.last(where: { $0.status == "failed" })?.detail ?? "真实 Skill 未完成") }
                phase("real-model-command")
                runtime.submit("/audit:handoff 给下一位同事一份简短交接", taskID: id)
                let until = Date().addingTimeInterval(100)
                while Date() < until, let task = tasks.task(id), [.ready, .running].contains(task.status) { await wait(0.1) }
                let final = tasks.task(id)!
                let prefixes = files.compactMap { ($0["sha256"] as? String).map { String($0.prefix(12)) } }
                checks["realModelFollowsSelectedCommandWithVerifiedFacts"] = final.status == .completed && ["结果", "核对", "未完成", "manifest.json"].allSatisfy(final.summary.contains) && prefixes.contains(where: final.summary.contains)
                checks["selectedCommandVersionRecordedInHumanInput"] = final.messages.last(where: \.isHumanInput)?.extensionReferences?.first?.sha256 == command.sha256 && final.messages.last(where: \.isHumanInput)?.content.hasPrefix("/audit:handoff") == true
                var live = report["live"] as? [String: Any] ?? [:]; live["commandStatus"] = final.status.rawValue; live["commandResult"] = final.summary; report["live"] = live
            }
            let uiTask = tasks.create(title: "扩展界面验收", workspace: workspace.path, mode: .ask)
            control.prepareExtensionCheckWindow(taskID: uiTask, manager: CommandLine.arguments.contains("--extension-ui-hold"))
            phase("finished")
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["scope"] = "Actual local Skill ZIP, source/script import, project and task boundaries, manual-only discovery, persisted disable, command expansion, conflict protection, snapshot fork and native UI. Live section uses the saved real model and unchanged budgets to inventory actual repository artwork/source/style files via the imported script, then select a custom handoff command. No simulated model or tool replies, accounts, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("extension-report.json")) }
    }
}
