import AppKit

@MainActor extension AppDelegate {
    func runAgentCanvasSkillCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "canvas-skill-process.json")
            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source.json"))) as! [String: String]
            guard let sourceID = seed["taskID"], let original = tasks.task(sourceID), original.status == .completed, let sourceCanvas = original.canvases?.first else { throw PetError("需要已有真实模型完成的画布任务") }
            let source = try tasks.canvases.source(sourceCanvas.id, taskID: sourceID), previousReceipts = original.modelReceipts?.count ?? 0
            guard previousReceipts > 0 else { throw PetError("来源没有实际模型请求记录") }
            let nativeFile = output.appendingPathComponent("canvas-skill-native-report.json")
            if fm.fileExists(atPath: nativeFile.path) {
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeFile)) as! [String: Any]
                guard saved["success"] as? Bool == true, saved["sourceHash"] as? String == source.record.hash, let values = saved["checks"] as? [String: Bool] else { throw PetError("原生复用检查未通过，不能跳过") }; checks = values
            } else {
            let specification = AgentCanvasSkillSpecification(name: "native-canvas-package", trigger: "根据实际销售数据生成画布", sources: "当前项目 sales.csv 的 item 和 amount", formatting: "金额两位小数，保留全部、仅B、图表与明细")
            let rendered = try await tasks.canvases.execute(call("canvas_inspect", ["id": sourceCanvas.id]), task: original)
            report["actualPreviewInspection"] = rendered.text
            checks["actualPreviewUsesRenderedCanvasAndCurrentSourceHash"] = !rendered.failed && tasks.canvases.previewImage(sourceCanvas, taskID: sourceID) != nil && !tasks.canvases.previewSignature(sourceCanvas, taskID: sourceID).isEmpty
            checks["nativePreviewDoesNotAddModelContextAttachmentsOrReceipts"] = tasks.task(sourceID)?.attachments?.count == original.attachments?.count && tasks.task(sourceID)?.modelReceipts?.count == previousReceipts
            let resources = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification)
            checks["packageContainsOnlyWorkflowAndExactActualModelSource"] = Set(resources.keys) == Set(["SKILL.md", "references/template.canvas.tsx"]) && resources["references/template.canvas.tsx"] == Data(source.code.utf8)
            do { _ = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: "stale", specification: specification); checks["staleCanvasCannotBePackaged"] = false } catch { checks["staleCanvasCannotBePackaged"] = true }
            var invalid = specification; invalid.name = "../outside"
            do { _ = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: invalid); checks["skillNameCannotEscapeChosenFolder"] = false } catch { checks["skillNameCannotEscapeChosenFolder"] = true }
            let folder: URL
            let existingFolder = output.appendingPathComponent(specification.name)
            if fm.fileExists(atPath: existingFolder.path) {
                guard try AgentExtensions.resourceData(AgentFiles(workspace: existingFolder.path)) == resources else { throw PetError("先前打包内容已变化，未覆盖") }; folder = existingFolder
            } else { folder = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification, parent: output) }
            do { _ = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification, parent: output); checks["existingPackageIsNotOverwritten"] = false } catch { checks["existingPackageIsNotOverwritten"] = try Data(contentsOf: folder.appendingPathComponent("SKILL.md")) == resources["SKILL.md"] }
            let imported: AgentExtensionItem
            if let existing = try tasks.extensions.catalog(workspace: original.workspace).first(where: { $0.name == specification.name && $0.kind == .skill }) { imported = existing }
            else { imported = try await tasks.extensions.importItem(folder, kind: .skill, project: false, workspace: original.workspace) }
            checks["exportedPackageMatchesActualImportedSkillResources"] = try AgentExtensions.resourceData(AgentFiles(workspace: imported.root.path)) == resources
            let link = output.appendingPathComponent("canvas-linked-package")
            if !fm.fileExists(atPath: link.path) { try fm.createSymbolicLink(at: link, withDestinationURL: folder) }
            var linked = specification; linked.name = link.lastPathComponent
            do { _ = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: linked, parent: output); checks["exportDoesNotFollowExistingDirectoryLink"] = false } catch { checks["exportDoesNotFollowExistingDirectoryLink"] = true }
            guard let fork = tasks.fork(sourceID) else { throw PetError("预览任务分支失败") }
            let forked = try tasks.canvases.update(sourceCanvas.id, source: source.code + "\n// independent preview version\n", expected: source.record.hash, taskID: fork)
            checks["changedSourceRejectsEarlierPreviewAndOriginalRemainsValid"] = tasks.canvases.previewImage(forked, taskID: fork) == nil && tasks.canvases.previewImage(sourceCanvas, taskID: sourceID) != nil
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("画布预览或 Skill 原生检查未通过") }
            try write(["success": true, "checks": checks, "sourceHash": source.record.hash], nativeFile.lastPathComponent)
            }
            tasks.canvases.closeAll(); control.showAgentTask(sourceID); control.show(tab: "chat")
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("画布预览或 Skill 原生检查未通过") }
            try write(["phase": "package-and-import", "sourceTaskID": sourceID, "sourceCanvasID": sourceCanvas.id, "sourceHash": source.record.hash, "appPID": getpid()], "canvas-skill-ui-ready.json")
            if CommandLine.arguments.contains("--live-agent") {
                let start = output.appendingPathComponent("start-canvas-skill-live"), startDeadline = Date().addingTimeInterval(1200)
                while Date() < startDeadline, !fm.fileExists(atPath: start.path) { await wait(0.1) }
                guard fm.fileExists(atPath: start.path) else { throw PetError("等待真实 Skill 打包及导入超时") }
                guard let selected = try tasks.extensions.catalog(workspace: output.appendingPathComponent("repo").path).first(where: { $0.kind == .skill && $0.name == "weekly-sales-panel" }) else { throw PetError("真实界面尚未导入 weekly-sales-panel") }
                let exported = output.appendingPathComponent("weekly-sales-panel"), importedFiles = try AgentExtensions.resourceData(AgentFiles(workspace: selected.root.path)), exportedFiles = try AgentExtensions.resourceData(AgentFiles(workspace: exported.path))
                checks["actualUIPackageAndImportedTemplateMatchOriginalSource"] = importedFiles == exportedFiles && importedFiles["references/template.canvas.tsx"] == Data(source.code.utf8)
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                let configured = ["context": preferences.contextLimit, "output": preferences.outputLimit]
                preferences.contextTokens = max(32768, preferences.contextTokens); preferences.replyTokens = max(2048, preferences.replyTokens); preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                report["preferences"] = ["saved": configured, "actual": ["context": preferences.contextLimit, "output": preferences.outputLimit], "productionSettingsWritten": false]
                let owner = output.appendingPathComponent("canvas-skill-live-task.json"), id: String
                let intent = "/skill:weekly-sales-panel 使用当前项目 sales.csv 重新生成销售画布，核对合计、行数及全部、仅B两种筛选。保留模板布局和交互，不修改输入文件。"
                if fm.fileExists(atPath: owner.path) {
                    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let previous = saved["taskID"], tasks.task(previous)?.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原真实 Skill 任务不存在，不能替换") }; id = previous
                    if tasks.task(id)?.status != .completed { runtime.start(id) }
                } else {
                    let profile = AgentProfile(name: "实际画布 Skill", description: "读取实际输入并复用画布工作流", instructions: "遵循选定 Skill，读取当前实际数据并核对画布。", tools: ["read_file", "list_directory"] + AgentCanvas.tools, readOnly: false, network: false, enabled: true, skills: [selected.id])
                    let (_, version) = try tasks.agents.document(), values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try tasks.agents.list() + [profile]))
                    try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: version)
                    id = try tasks.agents.createTask(profile.id, store: tasks, workspace: output.appendingPathComponent("repo").path); tasks.update(id) { $0.title = "画布 Skill 实际复用" }
                    guard runtime.submit(intent, taskID: id) else { throw PetError("真实 Skill 任务未开始：" + (runtime.submissionError ?? "")) }
                    try write(["taskID": id, "originalInputID": tasks.task(id)?.messages.first(where: \.isHumanInput)?.id ?? ""], owner.lastPathComponent)
                }
                var approvals = 0
                func approve() throws {
                    guard let task = tasks.task(id), task.status == .waiting, let call = task.pendingCalls.first else { return }
                    guard AgentCanvas.writes.contains(call.name), approvals < 16, call.name == "canvas_create" ? (task.canvases ?? []).isEmpty : task.canvases?.first?.id == call.object["id"] as? String else { throw PetError("真实 Skill 模型提出预期外审批") }
                    runtime.decide(taskID: id, callID: call.id, decision: "allow"); approvals += 1
                }
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    try approve(); let task = tasks.task(id)!
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实 Skill 任务失败：" + (task.events.last?.detail ?? "")) }; await wait(0.1)
                }
                guard let task = tasks.task(id), task.status == .completed, let canvas = task.canvases?.first else { throw PetError("真实 Skill 任务未完成") }
                let window = try await tasks.canvases.show(canvas.id, taskID: id), observed = try await window.inspect(), text = observed["text"] as? String ?? ""
                checks["actualModelRegeneratesWithDifferentCurrentCsvValues"] = text.contains("49.50") && text.contains("7.65") && !text.contains("19.90") && (observed["bar_count"] as? Int) == 3 && (observed["table_row_count"] as? Int) == 3
                checks["actualModelLoadsSkillAndReadsTemplateResource"] = task.activeSkills?.contains(where: { $0.id == selected.id }) == true && task.events.contains { $0.title == "read_skill_resource" && $0.status == "completed" }
                checks["reusedCanvasHasActualInlineSnapshot"] = tasks.canvases.previewImage(canvas, taskID: id) != nil
                tasks.canvases.closeAll(); control.showAgentTask(id); control.show(tab: "chat")
                try write(["phase": "reused", "taskID": id, "canvasID": canvas.id, "sourceHash": canvas.hash, "appPID": getpid()], "canvas-skill-ui-ready.json")
                if CommandLine.arguments.contains("--hold-ui") {
                    let deadline = Date().addingTimeInterval(1200)
                    while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-canvas-skill-ui").path) { try approve(); await wait(0.1) }
                }
                let final = tasks.task(id)!
                report["live"] = ["taskID": id, "canvasID": canvas.id, "sourceHash": final.canvases?.first?.hash ?? "", "model": preferences.model, "requests": final.modelReceipts?.count ?? 0, "inputTokens": final.inputTokens, "outputTokens": final.outputTokens, "renderedBeforeUI": observed, "skillID": selected.id, "approvals": final.approvals.filter { $0.decision == "allow" }.count]
            }
            let retainedHash = try tasks.canvases.source(sourceCanvas.id, taskID: sourceID).record.hash
            checks["originalRealModelMessagesAndReceiptsPreserved"] = tasks.task(sourceID)?.messages.map(\.id) == original.messages.map(\.id) && tasks.task(sourceID)?.modelReceipts?.count == previousReceipts && retainedHash == source.record.hash
            report["source"] = ["taskID": sourceID, "canvasID": sourceCanvas.id, "sourceHash": source.record.hash, "previousActualRequests": previousReceipts]
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; try write(report, "canvas-skill-report.json")
            tasks.canvases.closeAll(); runtime.stopAll()
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "canvas-skill-report.json"); agentRuntime?.stopAll() }
    }
}
