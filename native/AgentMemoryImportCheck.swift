import AppKit

@MainActor extension AppDelegate {
    func runMemoryImportCheck(_ output: URL) async {
        let phase = output.appendingPathComponent("memory-import-paused.json")
        let reportURL = output.appendingPathComponent("memory-import-report.json")
        func write(_ value: [String: Any], to file: URL) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        }
        var checks: [String: Bool] = [:]
        do {
            let tasks = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let service = tasks.dataImport
            let codex = output.appendingPathComponent(".codex"), codexFiles = codex.appendingPathComponent("memories_v2")
            let qoder = output.appendingPathComponent(".qoder/projects/harbor/memory")
            let project = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("lighthouse")
            let longText = Data(String(repeating: "公开记忆 · 第一路径 🐳。\n", count: 2400).utf8)
            let summaryText = Data("公开用户偏好 PUBLIC-CODEX\n".utf8)
            let projectText = Data("公开项目约定 PUBLIC-QODER\n".utf8)
            let original = Data("原项目主题应保留 PUBLIC-LOCAL\n".utf8)
            let primary = codexFiles.appendingPathComponent("MEMORY.md")
            let summary = codexFiles.appendingPathComponent("memory_summary.md")
            let deployment = qoder.appendingPathComponent("部署.md")
            let changing = qoder.appendingPathComponent("测试.md")
            let targetOriginal = project.appendingPathComponent(".bluefatfish/memory/部署.md")
            func finish() async throws {
                let deadline = Date().addingTimeInterval(30)
                while service.active && Date() < deadline { await wait(0.04) }
                guard !service.active else { throw PetError("记忆导入仍在运行") }
            }
            func installed(_ item: AgentImportCandidate) throws -> Data {
                try AgentMemoryImport.destinationURLs(item, store: tasks).reduce(into: Data()) { value, url in value.append(try Data(contentsOf: url)) }
            }
            if !FileManager.default.fileExists(atPath: phase.path) {
                let fm = FileManager.default
                for directory in [codexFiles, qoder, targetOriginal.deletingLastPathComponent(), other] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
                for (file, data) in [(primary, longText), (summary, summaryText), (deployment, projectText), (changing, Data("初次预览".utf8)), (targetOriginal, original)] { try data.write(to: file) }
                try Data("不属于长期记忆目录".utf8).write(to: codexFiles.appendingPathComponent("raw_memories.md"))
                try Data("测试配置文件标记".utf8).write(to: codex.appendingPathComponent("auth.json"))
                try fm.createSymbolicLink(at: qoder.appendingPathComponent("链接.md"), withDestinationURL: primary)
                try Data([0xFF, 0xFE, 0x61]).write(to: qoder.appendingPathComponent("格式错误.md"))
                try tasks.organization.register(project.path, mode: .coding)
                try tasks.organization.register(other.path, mode: .general)
                await service.detect(.codex, root: codex, category: .memory)
                let chosen = service.preview.filter { $0.issue == nil }
                checks["codexDetectsDurableFilesWithoutRawHistoryOrSettings"] = Set(chosen.map(\.title)) == Set(["MEMORY.md", "memory_summary.md"])
                checks["longUtf8MemoryPlansOrderedTopics"] = (chosen.first { $0.title == "MEMORY.md" }?.memory?.parts.count ?? 0) > 2
                do { try service.begin(.codex, root: qoder, ids: Set(chosen.map(\.id)), category: .memory); checks["startRejectsDifferentSourceDirectory"] = false }
                catch { checks["startRejectsDifferentSourceDirectory"] = error.localizedDescription.contains("重新检测") }
                let notify = service.onChange
                service.onChange = { [weak service] in
                    notify?()
                    if service?.batch?.state == "running", service?.batch?.items.filter({ $0.state == "imported" }).count == 1 { service?.pause() }
                }
                try service.begin(.codex, root: codex, ids: Set(chosen.map(\.id)), category: .memory)
                try await finish(); service.onChange = notify
                guard let batch = service.batch, let done = batch.items.first(where: { $0.state == "imported" }),
                      let pending = batch.items.first(where: { $0.state == "pending" }), let plan = pending.record.memory else { throw PetError("未取得实际暂停批次") }
                checks["pausePreservesCompletedAndPendingItems"] = batch.state == "paused" && batch.items.count == 2
                checks["firstImportedBytesMatchOriginal"] = try installed(done.record) == AgentMemoryImport.read(done.record, root: codex)
                let destination = try AgentMemory.importDestination(store: tasks, workspace: nil)
                let pendingBytes = try AgentMemoryImport.read(pending.record, root: codex)
                var signatures: [String: String] = [:]
                for (part, bytes) in zip(plan.parts, AgentMemoryImport.split(pendingBytes)) {
                    let file = destination.folder.appendingPathComponent(part.name)
                    try destination.files.writeData(bytes, to: file, permissions: 0o600, expectedTarget: "missing")
                    signatures[file.path] = try destination.files.entryMetadata(file).signature
                }
                let newFolder = codex.appendingPathComponent("memories")
                try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
                try Data("暂停后新增的记录".utf8).write(to: newFolder.appendingPathComponent("MEMORY.md"))
                guard checks.values.allSatisfy({ $0 }) else { throw PetError("暂停阶段失败：" + checks.filter { !$0.value }.map(\.key).joined(separator: ", ")) }
                try write(["batch": batch.id, "checks": checks, "signatures": signatures, "selected": tasks.selectedID ?? "", "tasks": tasks.tasks.count, "pid": getpid()], to: phase)
                return
            }
            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as! [String: Any]
            checks = seed["checks"] as! [String: Bool]
            checks["pausedBatchRestoresInAnotherProcess"] = service.batch?.id == seed["batch"] as? String && seed["pid"] as? Int != Int(getpid()) && service.batch?.state == "paused" && service.unfinished
            service.resume(); try await finish()
            guard let codexBatch = service.batch, codexBatch.state == "completed" else { throw PetError("恢复后导入未完成") }
            checks["resumingAppliesOnlyFrozenSelection"] = codexBatch.items.count == 2 && codexBatch.items.allSatisfy { $0.state == "imported" }
            let global = try AgentMemory.importDestination(store: tasks, workspace: nil)
            let signatures = seed["signatures"] as! [String: String]
            checks["alreadyWrittenPartsAreReusedOnResume"] = try signatures.allSatisfy { try global.files.entryMetadata(URL(fileURLWithPath: $0.key)).signature == $0.value }
            checks["splitMemoryReassemblesAllBytes"] = try codexBatch.items.allSatisfy { try installed($0.record) == AgentMemoryImport.read($0.record, root: codex) }
            checks["importedGlobalFilesKeepPrivatePermissions"] = try codexBatch.items.flatMap { try AgentMemoryImport.destinationURLs($0.record, store: tasks) }.allSatisfy { try global.files.entryMetadata($0).permissions == 0o600 }
            await service.detect(.codex, root: codex, category: .memory)
            checks["redetectSkipsIdenticalImportedFiles"] = service.preview.filter { $0.issue == "已经导入" }.count == 2 && service.preview.filter { $0.issue == nil }.count == 1
            await service.detect(.qoder, root: qoder, category: .memory)
            checks["qoderProjectRequiresProjectDestination"] = service.preview.isEmpty && service.issue?.contains("目标项目") == true
            await service.detect(.qoder, root: qoder, category: .memory, workspace: project.path)
            let records = service.preview
            guard let deploy = records.first(where: { $0.title == "部署.md" }) else { throw PetError("未检测到 Qoder 项目文件") }
            checks["invalidEncodingReportedAndLinkIgnored"] = records.contains { $0.title == "格式错误.md" && $0.issue?.contains("UTF-8") == true } && !records.contains { $0.title == "链接.md" }
            checks["previewNamesSeparateDestinationForConflict"] = deploy.memory?.parts.first?.name == "部署（Qoder）.md" && deploy.memory?.workspace == project.path
            do { try service.begin(.qoder, root: qoder, ids: [deploy.id], category: .memory, workspace: other.path); checks["startRejectsDifferentDestination"] = false }
            catch { checks["startRejectsDifferentDestination"] = error.localizedDescription.contains("重新检测") }
            let revised = Data("预览后更新 PUBLIC-NEW\n".utf8)
            try revised.write(to: changing, options: .atomic)
            try service.begin(.qoder, root: qoder, ids: Set(records.filter { $0.issue == nil }.map(\.id)), category: .memory, workspace: project.path)
            try await finish()
            checks["changedSourceFailsWithoutBlockingOtherItems"] = service.batch?.items.contains { $0.record.title == "测试.md" && $0.state == "failed" && $0.detail.contains("已更新") } == true
                && service.batch?.items.contains { $0.record.id == deploy.id && $0.state == "imported" } == true
            checks["qoderConflictPreservesOriginalAndCopiesUnderNewName"] = try Data(contentsOf: targetOriginal) == original && installed(deploy) == projectText
            checks["originMemoryFilesStayByteExact"] = try Data(contentsOf: primary) == longText && Data(contentsOf: summary) == summaryText && Data(contentsOf: deployment) == projectText && Data(contentsOf: changing) == revised
            checks["onlyChosenProjectReceivesProjectMemory"] = !(FileManager.default.fileExists(atPath: other.appendingPathComponent(".bluefatfish").path))
                && !(FileManager.default.fileExists(atPath: global.folder.appendingPathComponent("部署.md").path))
            checks["memoryImportDoesNotCreateOrSelectTasks"] = tasks.selectedID == seed["selected"] as? String && tasks.tasks.count == seed["tasks"] as? Int
            try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": 0], to: reportURL)
        } catch {
            try? write(["success": false, "checks": checks, "error": error.localizedDescription, "pid": getpid(), "modelRequests": 0], to: reportURL)
        }
    }
}
