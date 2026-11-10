import AppKit

@MainActor extension AppDelegate {
    func runAgentProfileDraftCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], blocked = 0
        let fm = FileManager.default
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("草稿原生检查不发送模型请求") }
            guard !fm.fileExists(atPath: output.appendingPathComponent("agent-draft-started.json").path) else { throw PetError("本轮检查已开始，不能重放") }
            try write(["appPID": getpid()], "agent-draft-started.json"); await wait(0.25)
            ensureAgent(); guard let store = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            runtime.modelRequestCheck = { blocked += 1; throw PetError("Agent 草稿检查禁止模型传输") }
            let workspace = output.appendingPathComponent("workspace"), source = workspace.appendingPathComponent("README.md"), input = try Data(contentsOf: source)
            let existing = AgentProfile(name: "保留的本机角色", description: "原有资料", instructions: "读取实际文件，不修改。")
            try store.agents.save(store.agents.encode([existing]), expectedHash: store.agents.document().1)
            let original = try store.agents.document(), id = store.create(title: "本机 Agent 草稿", workspace: workspace.path)
            store.update(id) { $0.mode = .ask; $0.draft = "保留原草稿，不发送。" }
            let args: [String: Any] = ["name": "公开文件核对员", "description": "只读核对公开 README", "instructions": "读取用户指定的 README，按实际行号列出依据；缺少证据时说明，不修改文件。"]
            func call(_ id: String, _ args: [String: Any], owner: String) async throws -> AgentToolResult {
                let tool = AgentToolCall(id: id, name: "draft_agent", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self))
                let tools = AgentTools(store: store, taskID: owner); guard try tools.approvalReason(for: tool) == nil else { throw PetError("生成本任务草稿不应修改角色配置") }
                return try await tools.execute(tool)
            }
            let result = try await call("actual-local-draft-1", args, owner: id)
            let receipt = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any], draftID = receipt["draft_id"] as! String
            let draft = try AgentProfileDrafts.load(draftID, taskID: id, store: store)
            checks["actualToolStoresOnlyTaskDraftAndKeepsOrdinaryAgentBytes"] = try store.agents.document().1 == original.1 && store.task(id)?.agentDrafts?.count == 1 && store.task(id)?.draft == "保留原草稿，不发送。" && receipt["saved"] as? Bool == false
            checks["draftUsesDisabledReadOnlyReviewDefaultsWithoutExtensions"] = !draft.profile.enabled && draft.profile.readOnly && !draft.profile.network && draft.profile.permission == .review && draft.profile.model.isEmpty && draft.profile.skills == nil && draft.profile.mcpServers == nil && draft.profile.pluginSource == nil
            checks["draftIsAbsentFromSavedAgentsAndExecutorDirectory"] = try !store.agents.list().contains { $0.id == draft.profile.id }
            let repeated = try await call("actual-local-draft-1", args, owner: id)
            checks["sameCallIsIdempotentAndReturnsSameDraft"] = repeated.text == result.text && store.task(id)?.agentDrafts?.count == 1
            var conflict = args; conflict["name"] = "另一份内容"
            var rejected = false; do { _ = try await call("actual-local-draft-1", conflict, owner: id) } catch { rejected = true }
            checks["sameCallCannotOverwriteOriginalDraft"] = rejected && store.task(id)?.agentDrafts?.first?.profile.name == args["name"] as? String
            var invalid: [[String: Any]] = [args.merging(["enabled": true]) { _, n in n }, args.merging(["tools": ["write_file"]]) { _, n in n }, args.merging(["description": ""]) { _, n in n }, args.merging(["name": "bad\nname"]) { _, n in n }, args.merging(["instructions": String(repeating: "x", count: 24_001)]) { _, n in n }]
            invalid.append(args.merging(["permission": "automatic"]) { _, n in n })
            var invalidCount = 0; for (i, value) in invalid.enumerated() { do { _ = try await call("invalid-\(i)", value, owner: id) } catch { invalidCount += 1 } }
            checks["invalidAndPrivilegeFieldsAreRejectedWithoutSaving"] = try invalidCount == invalid.count && store.agents.document().1 == original.1 && store.task(id)?.agentDrafts?.count == 1
            var tampered = draft; tampered.profile.enabled = true
            rejected = false; do { _ = try AgentProfileDrafts.checked(tampered, taskID: id, agents: store.agents) } catch { rejected = true }
            checks["persistedDraftCannotSmuggleActivation"] = rejected
            let other = store.create(title: "没有工作区的草稿")
            rejected = false; do { _ = try AgentProfileDrafts.load(draftID, taskID: other, store: store) } catch { rejected = true }
            checks["anotherTaskCannotConfigureForeignDraft"] = rejected
            let noProject = try await call("actual-no-project", args.merging(["name": "无工作区核对员"]) { _, n in n }, owner: other)
            checks["draftingWorksWithoutWorkspace"] = noProject.text.contains("无工作区核对员") && store.task(other)?.workspace == nil
            rejected = false; do { try AgentProfileDrafts.markSaved(draftID, taskID: id, profileID: draft.profile.id, store: store) } catch { rejected = true }
            checks["unsavedDraftCannotClaimSaved"] = rejected && store.task(id)?.agentDrafts?.first?.savedAt == nil
            let reopened = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let loaded = try AgentProfileDrafts.load(draftID, taskID: id, store: reopened)
            checks["actualReloadKeepsDraftAndOriginalProfileID"] = loaded.profile.id == draft.profile.id && loaded.profile.instructions == args["instructions"] as? String && loaded.savedAt == nil
            let index = try JSONSerialization.jsonObject(with: Data(contentsOf: store.directory.appendingPathComponent("index.json"))) as! [String: Any]
            checks["draftBodyIsNotDuplicatedIntoTaskIndex"] = (index["tasks"] as? [[String: Any]])?.allSatisfy { $0["agentDrafts"] == nil } == true
            var profiles = try store.agents.decode(store.agents.document().0); profiles.append(draft.profile)
            try store.agents.save(store.agents.encode(profiles), expectedHash: original.1)
            try AgentProfileDrafts.markSaved(draftID, taskID: id, profileID: draft.profile.id, store: store)
            let marked = store.task(id)?.agentDrafts?.first?.savedAt
            try AgentProfileDrafts.markSaved(draftID, taskID: id, profileID: draft.profile.id, store: store)
            checks["onlyActualSavedProfileMarksDraftAndRepeatedMarkKeepsTimestamp"] = marked != nil && store.task(id)?.agentDrafts?.first?.savedAt == marked
            rejected = false; do { try store.agents.configureDraft(draft.profile.id, taskID: other, store: store) } catch { rejected = true }
            checks["savingDisabledProfileDoesNotMakeItAssignable"] = rejected
            try store.agents.setEnabled(draft.profile.id, true)
            try store.agents.configureDraft(draft.profile.id, taskID: other, store: store)
            checks["explicitEnableAllowsExistingExecutorSelectionWithoutSending"] = store.task(other)?.agent?.profile.id == draft.profile.id && store.task(other)?.messages.isEmpty == true
            let read = AgentToolCall(id: "actual-read", name: "read_file", arguments: "{\"path\":\"README.md\"}")
            let assigned = store.create(title: "已保存角色实际读文件", workspace: workspace.path)
            try store.agents.configureDraft(draft.profile.id, taskID: assigned, store: store)
            let actualRead = try await AgentTools(store: store, taskID: assigned).execute(read)
            let firstLine = String(String(decoding: input, as: UTF8.self).split(separator: "\n").first!.prefix(60))
            checks["savedRoleActuallyReadsPublicSourceWithInheritedReadOnlyTools"] = !actualRead.failed && actualRead.text.contains(firstLine) && actualRead.sources.contains(source.absoluteString)
            rejected = false; do { _ = try await AgentTools(store: store, taskID: assigned).execute(AgentToolCall(id: "denied-write", name: "write_file", arguments: "{\"path\":\"forbidden.txt\",\"content\":\"no\"}")) } catch { rejected = true }
            checks["savedDraftDoesNotExpandReadOnlyRolePermissions"] = rejected && !fm.fileExists(atPath: workspace.appendingPathComponent("forbidden.txt").path)
            let version = try store.agents.document(), config = output.appendingPathComponent("profile/extensions/agents.json"), writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); writer.arguments = ["-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b'\\n')", config.path]; try writer.run(); writer.waitUntilExit()
            let externalBytes = try Data(contentsOf: config)
            rejected = false; do { try store.agents.save(version.0, expectedHash: version.1) } catch { rejected = true }
            checks["independentProcessChangeRejectsStaleSaveAndPreservesEveryByte"] = try rejected && writer.terminationStatus == 0 && Data(contentsOf: config) == externalBytes
            report["independentWriterPID"] = writer.processIdentifier
            for parentLink in [false, true] {
                let root = output.appendingPathComponent(parentLink ? "parent-link-profile" : "file-link-profile"), target = output.appendingPathComponent(parentLink ? "parent-link-original" : "file-link-original")
                try fm.createDirectory(at: root, withIntermediateDirectories: true); try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let originalFile = target.appendingPathComponent("agents.json"); try externalBytes.write(to: originalFile)
                if parentLink { try fm.createSymbolicLink(at: root.appendingPathComponent("extensions"), withDestinationURL: target) }
                else { try fm.createDirectory(at: root.appendingPathComponent("extensions"), withIntermediateDirectories: true); try fm.createSymbolicLink(at: root.appendingPathComponent("extensions/agents.json"), withDestinationURL: originalFile) }
                let linked = AgentProfiles(profile: root); rejected = false; do { try linked.save(version.0, expectedHash: AgentFiles.hash(externalBytes)) } catch { rejected = true }
                checks[parentLink ? "profileParentLinkCannotRedirectSave" : "profileFileLinkCannotRedirectSave"] = try rejected && Data(contentsOf: originalFile) == externalBytes
            }
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
            rejected = false; do { try store.agents.save(version.0, expectedHash: AgentFiles.hash(externalBytes)) } catch { rejected = true }
            checks["readOnlyProfileIsNotReplacedBySave"] = try rejected && Data(contentsOf: config) == externalBytes
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            for i in 2...8 { _ = try await call("bounded-draft-\(i)", args.merging(["name": "待审阅 \(i)"]) { _, n in n }, owner: id) }
            rejected = false; do { _ = try await call("ninth-draft", args, owner: id) } catch { rejected = true }
            checks["eightDraftLimitPreservesExistingDrafts"] = rejected && store.task(id)?.agentDrafts?.count == 8
            checks["allModesExposeDraftOnlyWhenAgentsGroupIsLoaded"] = AgentMode.allCases.allSatisfy { mode in
                let loaded = AgentTools.definitions(mode: mode, groups: ["agents"]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                let unloaded = AgentTools.definitions(mode: mode, groups: []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                return loaded.contains("draft_agent") && !unloaded.contains("draft_agent")
            }
            checks["publicReadmeAndOriginalOrdinaryProfileRemain"] = try Data(contentsOf: source) == input && store.agents.decode(store.agents.document().0).contains { $0.id == existing.id && !$0.enabled && $0.instructions == existing.instructions }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Agent 草稿原生检查未通过") }
            let ui = store.create(title: "创建 README 核对员", workspace: workspace.path)
            store.update(ui) { $0.draft = "保留的会话草稿，不发送。" }
            let uiResult = try await call("actual-window-draft", args.merging(["name": "README 核对员"]) { _, n in n }, owner: ui)
            let uiDraft = try JSONSerialization.jsonObject(with: Data(uiResult.text.utf8)) as! [String: Any]
            let binary = try Data(contentsOf: Bundle.main.executableURL!), hash = AgentFiles.hash(binary)
            report["appPID"] = getpid(); report["binaryHash"] = hash; report["taskID"] = ui; report["draftID"] = uiDraft["draft_id"]; report["draftReceipt"] = uiDraft; report["sourceHash"] = AgentFiles.hash(input)
            if CommandLine.arguments.contains("--hold-draft-ui") {
                control.showAgentTask(ui); control.show(tab: "chat")
                try write(report.merging(["checks": checks, "modelRequests": blocked]) { _, n in n }, "agent-draft-ui-ready.json")
                var last = ""; let end = Date().addingTimeInterval(7200)
                while Date() < end && !fm.fileExists(atPath: output.appendingPathComponent("finish-agent-draft-ui").path) {
                    if let name = try? String(contentsOf: output.appendingPathComponent("capture-agent-draft-ui"), encoding: .utf8), name != last, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                        last = name; var value = control.organizationSnapshot(); value["modelRequests"] = blocked; value["appPID"] = getpid(); value["binaryHash"] = hash; value["activeJobs"] = store.tasks.contains { runtime.isRunning($0.id) }; try write(value, "native-agent-draft-ui-" + name + ".json")
                    }; await wait(0.25)
                }
            }
            checks["allActualTasksHaveNoModelReceiptOrInventedAssistantReply"] = blocked == 0 && store.tasks.compactMap { store.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains { $0.role == "assistant" } }
            report["blockedModelAttempts"] = blocked; report["activeJobs"] = store.tasks.contains { runtime.isRunning($0.id) }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? write(report, "agent-draft-result.json")
    }
}
