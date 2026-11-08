import AppKit

@MainActor extension AppDelegate {
    func runAgentMarkdownTableCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("表格验收只编辑实际本地文档，不调用模型") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: workspace.path)
            let fixtures = output.appendingPathComponent("table-fixtures"), guide = try files.resolve("docs/AGENT-READING.md")
            let initial = try Data(contentsOf: fixtures.appendingPathComponent("initial.bin"))
            try files.writeData(initial, to: guide)
            let input = try AgentTextFile.decode(initial), original = input.text
            let rendered = AgentMarkdownDocument.render(original, document: guide, files: files, width: 600)
            guard let region = rendered.regions.first(where: { $0.isCell && (try? AgentMarkdownEditing.value($0, in: original)) == "当前块的 Markdown" }), case .cell(let start, _, _) = region.kind else { throw PetError("项目实际文档的表格已变化") }
            checks["actualProjectTableHasHeaderAndThreeDataRows"] = try AgentMarkdownEditing.table(in: original, at: start).rows.count == 4
            checks["actualUTF16BOMCRLFFileDecodesLosslessly"] = try input.format == AgentTextFormat(encoding: .utf16LE, bom: true) && input.format.encode(original) == initial && original.contains("\r\n")
            let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("table-vectors.json"))) as! [[String: Any]]
            for entry in cases {
                let source = entry["source"] as! String, table = AgentMarkdownDocument.render(source, document: guide, files: files, width: 600).regions.first(where: { $0.isCell })
                guard let table, case .cell(let position, _, _) = table.kind, let action = AgentMarkdownEditing.TableAction(rawValue: entry["action"] as! Int) else { throw PetError("独立表格样例无有效表格") }
                do {
                    let result = try AgentMarkdownEditing.changingTable(in: source, at: position, row: entry["row"] as! Int, column: entry["column"] as! Int, action: action)
                    checks[entry["name"] as! String] = entry["reject"] as? Bool != true && result.source == entry["expected"] as? String
                } catch { checks[entry["name"] as! String] = entry["reject"] as? Bool == true }
            }
            ensureAgent(); guard let tasks = agentStore else { throw PetError("表格检查任务未初始化") }; _ = control
            let id = tasks.create(title: "Markdown 表格编辑", workspace: workspace.path, mode: .agent)
            tasks.update(id) { $0.artifacts = [guide.path]; $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "保留的B草稿" }
            let readonly = try files.resolve("readonly/actual-guide.md"); try files.writeData(initial, to: readonly); try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonly.path)
            tasks.update(id) { $0.artifacts = [readonly.path] }
            let locked = AgentRecordWindow(store: tasks, taskID: id, section: 1), lockedState = await locked.markdownEditingReadback()
            checks["readOnlyFileDoesNotExposeTableOperations"] = (lockedState["preview"] as? [String: Any])?["canEdit"] as? Bool == false && (lockedState["preview"] as? [String: Any])?["tableMenuVisible"] as? Bool == false; locked.close()
            tasks.update(id) { $0.artifacts = [guide.path] }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 1, value: guide.path) else { throw PetError("实际表格记录窗口未打开") }
            let initialState = await records.markdownEditingReadback()
            checks["actualRecordStartsWithExactEncodedBytesAndHiddenTableMenu"] = initialState["draftHash"] as? String == AgentFiles.hash(initial) && initialState["dirty"] as? Bool == false && (initialState["preview"] as? [String: Any])?["tableMenuVisible"] as? Bool == false
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("表格操作前的原生检查未通过") }
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": binaryHash, "taskID": id, "otherTaskID": other, "workspace": workspace.path, "file": guide.path, "checks": checks, "modelsCalled": false]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-table-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-markdown-table-ui").path) {
                if let request = try? String(contentsOf: output.appendingPathComponent("capture-table-state"), encoding: .utf8), request != capture, request.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = request; var state = await records.markdownEditingReadback(); state["appPID"] = ProcessInfo.processInfo.processIdentifier
                    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-table-" + capture + ".json"))
                }
                await wait(0.25)
            }
            if let bytes = try? Data(contentsOf: output.appendingPathComponent("markdown-table-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            let final = await records.markdownEditingReadback(); try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-table-final.json"))
            checks["actualConflictingExternalFilePreserved"] = try files.readData(guide) == Data(contentsOf: fixtures.appendingPathComponent("external.bin"))
            checks["actualUnsavedTableDraftRetained"] = try final["encodedDraftBase64"] as? String == Data(contentsOf: fixtures.appendingPathComponent("unsaved.bin")).base64EncodedString() && final["dirty"] as? Bool == true
            checks["bothComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }; checks["noModelRequestsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-table-report.json"))
    }
}
