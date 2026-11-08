import AppKit

@MainActor extension AppDelegate {
    func runAgentOfficeCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func object(_ result: AgentToolResult) throws -> [String: Any] { guard let data = result.text.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("实际办公结果不可读") }; return value }
        func waitFor(_ name: String) async throws {
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent(name).path) { await wait(0.2) }
            guard fm.fileExists(atPath: output.appendingPathComponent(name).path) else { throw PetError("等待实际界面验收超时：" + name) }
        }
        defer { agentStore?.offices.closeAll(); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            let executable = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            let resourceRoot = Bundle.main.resourceURL!.appendingPathComponent("web/office")
            let resourceHash = try await Task.detached {
                let files = try AgentFiles(workspace: resourceRoot.path)
                guard let walk = fm.enumerator(at: resourceRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { throw PetError("办公资源不可读取") }
                var manifest: [String] = []
                while let file = walk.nextObject() as? URL { if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { manifest.append(files.relative(file) + ":" + (try files.fileHash(file))) } }
                return AgentFiles.hash(Data(manifest.sorted().joined(separator: "\n").utf8))
            }.value
            let candidateHash = AgentFiles.hash(Data((binaryHash + "\n" + resourceHash).utf8))
            try write(["appPID": getpid(), "arguments": CommandLine.arguments, "binaryHash": binaryHash, "resourceHash": resourceHash, "candidateHash": candidateHash], "office-process.json")
            let nativeName = "office-native-" + String(candidateHash.prefix(12)) + ".json", nativeFile = output.appendingPathComponent(nativeName)
            if fm.fileExists(atPath: nativeFile.path) {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeFile)) as! [String: Any]
                guard previous["success"] as? Bool == true, previous["candidateHash"] as? String == candidateHash, let values = previous["checks"] as? [String: Bool] else { throw PetError("同一候选的办公原生检查尚未完成，保留原记录") }; checks = values; report["native"] = previous
            } else {
                let workspace = output.appendingPathComponent("native-" + String(candidateHash.prefix(12)))
                try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
                for format in AgentOffice.formats {
                    let target = workspace.appendingPathComponent("sample." + format)
                    guard !fm.fileExists(atPath: target.path) else { throw PetError("本次原生输入已存在，保留实际文件，不重新覆盖") }
                    try fm.copyItem(at: output.appendingPathComponent("originals/sample." + format), to: target)
                }
                let id = tasks.create(title: "办公原生文件验收", workspace: workspace.path), tools = AgentTools(store: tasks, taskID: id)
                tasks.update(id) { $0.permission = .review; $0.toolGroups = ["office"] }
                var hashes: [String: String] = [:]
                for format in AgentOffice.formats {
                    let name = "sample." + format, args: [String: Any] = format == "xlsx" ? ["path": name, "sheet": "审阅", "range": "A1"] : ["path": name]
                    let actual = try object(await tools.execute(call("office_read", args))), version = actual["version"] as? String ?? "", hash = actual["sha256"] as? String ?? ""
                    var step: [String: Any]
                    if format == "docx" {
                        guard let paragraph = (actual["paragraphs"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "审阅人：待填写" }) else { throw PetError("实际Word中没有待填写段落") }
                        step = ["op": "replaceText", "target": ["kind": "paragraph", "story": paragraph["story"]!, "paraId": paragraph["id"]!], "text": "审阅人：原生验收", "expect": ["text": "审阅人：待填写"]]
                    } else if format == "xlsx" {
                        guard let sheet = actual["sheet"] as? String else { throw PetError("实际工作表不存在") }
                        step = ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "A1"]], "inputs": [["审阅人：原生验收"]]]
                    } else {
                        guard let story = (actual["stories"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "审阅人：待填写" }) else { throw PetError("实际幻灯片中没有待填写文字") }
                        step = ["op": "replaceText", "target": ["kind": "search", "within": ["slideId": story["slideId"]!, "shapeId": story["shapeId"]!, "storyId": story["id"]!], "text": "审阅人：待填写"], "text": "审阅人：原生验收", "expect": ["text": "审阅人：待填写"]]
                    }
                    let request: [String: Any] = ["expectVersion": version, "steps": [step]], edits = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
                    let edit = try call("office_edit", ["path": name, "expected_hash": hash, "edits": edits])
                    checks[format + "NativeSaveUsesReviewApproval"] = try tools.approvalReason(for: edit) != nil
                    let edited = try object(await tools.execute(edit))
                    let changed = try object(await tools.execute(call("office_read", args))), files = try AgentFiles(workspace: workspace.path)
                    let savedHash = try files.fileHash(workspace.appendingPathComponent(name)); hashes[name] = savedHash
                    let marker: Bool
                    if format == "docx" { marker = (changed["paragraphs"] as? [[String: Any]])?.contains { $0["text"] as? String == "审阅人：原生验收" } == true }
                    else if format == "xlsx" { marker = (changed["cells"] as? [[String: Any]])?.contains { ($0["value"] as? [String: Any])?["value"] as? String == "审阅人：原生验收" } == true }
                    else { marker = (changed["stories"] as? [[String: Any]])?.contains { $0["text"] as? String == "审阅人：原生验收" } == true }
                    checks[format + "ActualStructuredEditSavedAndReadBack"] = edited["sha256"] as? String == savedHash && changed["sha256"] as? String == savedHash && savedHash != hash && marker
                    checks[format + "ActualCheckpointHasBeforeAndAfter"] = tasks.task(id)?.changes.contains { $0.path == workspace.appendingPathComponent(name).path && $0.beforeHash == hash && $0.afterHash == savedHash && $0.backup != nil } == true
                    var stale = request; stale["expectVersion"] = "stale-version"
                    do { _ = try await tools.execute(call("office_edit", ["path": name, "expected_hash": savedHash, "edits": String(decoding: try JSONSerialization.data(withJSONObject: stale), as: UTF8.self)])); checks[format + "StaleVersionRefusesWrite"] = false }
                    catch let error as AgentOfficeEditError {
                        let unchanged = try files.fileHash(workspace.appendingPathComponent(name)) == savedHash
                        checks[format + "StaleVersionRefusesWrite"] = error.code == "stale-version" && unchanged
                    }
                    catch { checks[format + "StaleVersionRefusesWrite"] = false }
                }
                tasks.update(id) { $0.mode = .ask }
                do { _ = try await tools.execute(call("office_create", ["path": "blocked.docx"])); checks["askModeCannotCreateOfficeFile"] = false } catch { checks["askModeCannotCreateOfficeFile"] = !fm.fileExists(atPath: workspace.appendingPathComponent("blocked.docx").path) }
                tasks.update(id) { $0.mode = .agent }
                do { _ = try await tools.execute(call("office_read", ["path": "../outside.docx"])); checks["officePathCannotEscapeProject"] = false } catch { checks["officePathCannotEscapeProject"] = true }
                let linked = workspace.appendingPathComponent("linked.docx"); try fm.createSymbolicLink(at: linked, withDestinationURL: output.appendingPathComponent("originals/sample.docx"))
                do { _ = try await tools.execute(call("office_read", ["path": linked.path])); checks["officeDoesNotFollowFinalFileLink"] = false } catch { checks["officeDoesNotFollowFinalFileLink"] = true }
                let other = tasks.create(title: "办公另一个任务", workspace: workspace.path)
                do { _ = try await tasks.offices.show(workspace.appendingPathComponent("sample.docx").path, taskID: other); checks["anotherTaskCannotTakeOverOpenDocument"] = false } catch { checks["anotherTaskCannotTakeOverOpenDocument"] = true }
                tasks.offices.closeAll()
                tasks.update(id) { $0.archived = true }
                let archived = try await tasks.offices.show(workspace.appendingPathComponent("sample.docx").path, taskID: id)
                let archivedContent = try await archived.inspect()
                checks["archivedOfficeOutputRemainsReadable"] = (archivedContent["paragraphs"] as? [[String: Any]])?.contains { $0["text"] as? String == "审阅人：原生验收" } == true
                do { try await archived.saveDocument(); checks["archivedOfficeOutputCannotBeSaved"] = false } catch { checks["archivedOfficeOutputCannotBeSaved"] = true }
                tasks.offices.closeAll(); tasks.update(id) { $0.archived = false }
                let strictID = tasks.create(title: "办公检查点故障保护", workspace: workspace.path), backups = try tasks.backupDirectory(strictID)
                try AgentFiles(workspace: backups.path).writeData(Data("blocked backup directory".utf8), to: backups.appendingPathComponent("objects"))
                do { _ = try await tasks.offices.create("checkpoint-blocked.docx", taskID: strictID); checks["officeCheckpointFailureDoesNotWriteFile"] = false }
                catch { checks["officeCheckpointFailureDoesNotWriteFile"] = !fm.fileExists(atPath: workspace.appendingPathComponent("checkpoint-blocked.docx").path) }
                for format in AgentOffice.formats {
                    let created = try await tasks.offices.create("blank." + format, taskID: id)
                    let observed = try await created.inspect()
                    checks[format + "ActualBlankTemplateOpens"] = !(observed["version"] as? String ?? "").isEmpty && created.openedHash.count == 64
                    created.finishClose()
                }
                let files = try AgentFiles(workspace: workspace.path), tooLarge = workspace.appendingPathComponent("bounded-copy.docx")
                do { _ = try files.copyFile(workspace.appendingPathComponent("sample.docx"), from: files, to: tooLarge, maximum: 10); checks["copySizeBoundLeavesNoPartialFile"] = false } catch { checks["copySizeBoundLeavesNoPartialFile"] = !fm.fileExists(atPath: tooLarge.path) }
                let privateTask = tasks.create(title: "办公私有数据边界", workspace: tasks.directory.deletingLastPathComponent().path)
                do { _ = try tasks.offices.file("private.docx", taskID: privateTask); checks["officeCannotReadAppPrivateProfile"] = false } catch { checks["officeCannotReadAppPrivateProfile"] = true }
                let assets = Bundle.main.resourceURL!.appendingPathComponent("web/office"), pinned = try AgentOffice.snapshot(files: files, file: workspace.appendingPathComponent("sample.docx"))
                let server = try AgentOfficeHTTP(assets: assets, document: pinned.file), base = try await server.start()
                defer { server.stop(); try? fm.removeItem(at: pinned.folder) }
                let (bytes, response) = try await URLSession.shared.data(from: base.appendingPathComponent("document"))
                checks["loopbackReturnsOnlyExactPinnedDocument"] = (response as? HTTPURLResponse)?.statusCode == 200 && AgentFiles.hash(bytes) == pinned.hash
                for (name, url, header, value, method) in [("wrongCapability", base.deletingLastPathComponent().appendingPathComponent("wrong/document"), "", "", "GET"), ("unknownRoute", base.appendingPathComponent("../outside.docx"), "", "", "GET"), ("crossOrigin", base.appendingPathComponent("document"), "Origin", "https://untrusted.example", "GET"), ("crossSite", base.appendingPathComponent("document"), "Sec-Fetch-Site", "cross-site", "GET"), ("writeMethod", base.appendingPathComponent("document"), "", "", "POST")] {
                    var request = URLRequest(url: url); request.httpMethod = method; if !header.isEmpty { request.setValue(value, forHTTPHeaderField: header) }
                    let (data, response) = try await URLSession.shared.data(for: request)
                    checks["loopbackRefuses_" + name] = data.isEmpty && (response as? HTTPURLResponse)?.statusCode == (method == "POST" ? 405 : 404)
                }
                let native: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks, "binaryHash": binaryHash, "resourceHash": resourceHash, "candidateHash": candidateHash, "taskID": id, "workspace": workspace.path, "hashes": hashes]
                try write(native, nativeName); report["native"] = native
                guard checks.values.allSatisfy({ $0 }) else { throw PetError("办公原生检查未通过，请核对原报告") }
            }
            if CommandLine.arguments.contains("--live-agent") {
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                let productionOutput = preferences.outputLimit
                if let flag = CommandLine.arguments.firstIndex(of: "--office-output-limit") {
                    guard flag + 1 < CommandLine.arguments.count, let limit = Int(CommandLine.arguments[flag + 1]), (512...4096).contains(limit) else { throw PetError("办公验收回复上限须为512至4096") }
                    preferences.replyTokens = limit
                }
                try preferences.validateModel()
                preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                report["preferences"] = ["model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "productionOutput": productionOutput, "productionSettingsWritten": false]
                let workspace = output.appendingPathComponent("repo"), owner = output.appendingPathComponent("office-live-task.json"), id: String
                let intent = "分别用办公工具读取 sample.docx、sample.xlsx、sample.pptx。把Word段落和第一张幻灯片中的“审阅人：待填写”，以及Excel“审阅”工作表A1的同样文字，改为“审阅人：海盐-2086”。保留其他内容、样式、表格、公式、图片、页眉页脚和两张幻灯片。每份文件保存后用office_read重新核对实际文字。只用办公工具，不用终端，不创建其他文件。完成后简短说明三份实际保存结果。"
                if fm.fileExists(atPath: owner.path) {
                    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let previous = saved["taskID"], tasks.task(previous)?.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原办公真实任务不存在，不能替换") }; id = previous
                    if tasks.task(id)?.status != .completed { runtime.start(id) }
                } else {
                    let profile = AgentProfile(name: "办公实际文件审阅", description: "仅编辑指定办公文件", instructions: "按用户要求处理三份实际文件，保存后读取核对。先读取实际sha256/version及编辑格式，不根据示例猜测目标ID，不使用其他工具。", tools: ["office_read", "office_edit"], readOnly: false, network: false, enabled: true)
                    let (_, version) = try tasks.agents.document(), values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try tasks.agents.list() + [profile]))
                    try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: version)
                    id = try tasks.agents.createTask(profile.id, store: tasks, workspace: workspace.path); tasks.update(id) { $0.title = "办公文件实际审阅"; $0.permission = .review; $0.toolGroups = ["office"] }
                    guard runtime.submit(intent, taskID: id) else { throw PetError("真实办公任务未开始：" + (runtime.submissionError ?? "")) }
                    try write(["taskID": id, "originalInputID": tasks.task(id)?.messages.first(where: \.isHumanInput)?.id ?? ""], owner.lastPathComponent)
                }
                let deadline = Date().addingTimeInterval(1500)
                while Date() < deadline {
                    guard let task = tasks.task(id) else { throw PetError("真实办公任务已丢失") }
                    let receipts = task.modelReceipts ?? []
                    if receipts.count > 50 || receipts.filter({ $0.purpose == "conversation" }).count > 32 { runtime.cancel(id); throw PetError("真实办公任务超过32次对话／50次总请求上限，保留原任务") }
                    if task.status == .waiting, let pending = task.pendingCalls.first {
                        guard pending.name == "office_edit", ["sample.docx", "sample.xlsx", "sample.pptx"].contains(URL(fileURLWithPath: pending.object["path"] as? String ?? "").lastPathComponent), task.approvals.filter({ $0.decision == "allow" }).count < 6 else { throw PetError("模型提出预期外办公审批") }
                        runtime.decide(taskID: id, callID: pending.id, decision: "allow")
                    }
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实办公任务停止：" + (task.events.last?.detail ?? "")) }; await wait(0.2)
                }
                guard let task = tasks.task(id), task.status == .completed else { throw PetError("真实办公任务仍未完成，保留原始记录") }
                report["live"] = ["taskID": id, "model": preferences.model, "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "approvals": task.approvals.filter { $0.decision == "allow" }.count, "artifacts": task.artifacts]
                try write(report["live"] as! [String: Any], "office-live-result.json")
            }
            tasks.offices.closeAll()
            let ui = output.appendingPathComponent("ui"), uiOwner = output.appendingPathComponent("office-ui-task.json"), uiID: String
            if fm.fileExists(atPath: uiOwner.path) { uiID = (try JSONSerialization.jsonObject(with: Data(contentsOf: uiOwner)) as! [String: String])["taskID"]! }
            else {
                try fm.createDirectory(at: ui, withIntermediateDirectories: true)
                for format in AgentOffice.formats { try fm.copyItem(at: output.appendingPathComponent((CommandLine.arguments.contains("--live-agent") ? "repo/" : "originals/") + "sample." + format), to: ui.appendingPathComponent("sample." + format)) }
                uiID = tasks.create(title: "办公窗口实际验收", workspace: ui.path); tasks.update(uiID) { $0.artifacts = AgentOffice.formats.map { ui.appendingPathComponent("sample." + $0).path } }
                try write(["taskID": uiID], uiOwner.lastPathComponent)
            }
            control.showAgentTask(uiID); control.show(tab: "chat")
            _ = try await tasks.offices.show(ui.appendingPathComponent("sample.docx").path, taskID: uiID)
            try write(["appPID": getpid(), "taskID": uiID, "workspace": ui.path, "phase": "manual-edit", "binaryHash": binaryHash], "office-ui-ready.json")
            if CommandLine.arguments.contains("--hold-ui") {
                try await waitFor("finish-office-ui")
                let data = try Data(contentsOf: output.appendingPathComponent("office-ui-acceptance.json"))
                let required = ["wordManualSaveAndReopen", "xlsxManualSaveAndReopen", "pptxManualSaveAndReopen", "conflictRefusesOverwrite", "saveAsPreservesBuffer", "externalDiskFileUnchanged", "unsavedSendKeepsDraftAndMakesNoRequest", "quitOffersContinueEditing", "wordImageVisible", "pptxChineseSpacingCorrect", "commonControlsLocalized"]
                guard data.count <= 16_000, let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], ui["candidateHash"] as? String == candidateHash, ui["appPID"] as? Int == Int(getpid()), let values = ui["checks"] as? [String: Bool], required.allSatisfy({ values[$0] == true }) else { throw PetError("实际办公窗口验收未通过，保留原文件与报告") }
                report["ui"] = ui
            }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["binaryHash"] = binaryHash
            try write(report, "office-report.json")
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            report["details"] = (error as NSError).userInfo.filter { ["WKJavaScriptExceptionMessage", "WKJavaScriptExceptionLineNumber", "WKJavaScriptExceptionColumnNumber"].contains($0.key) }.mapValues { String(describing: $0) }
            try? write(report, "office-report.json")
        }
    }
}
