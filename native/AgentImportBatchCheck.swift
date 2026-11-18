import Foundation

@MainActor extension AppDelegate {
    func checkMixedImport(_ output: URL, tasks: AgentStore, binaryHash: String) async throws {
        let files = FileManager.default, importer = tasks.dataImport
        let phase = output.appendingPathComponent("mixed-import-paused.json")
        let project = output.appendingPathComponent("Project"), codex = output.appendingPathComponent("Source tasks")
        let memory = output.appendingPathComponent("Source memories"), skills = output.appendingPathComponent("Source skills")
        let route = AgentImportRoute(source: .codex, category: .tasks, root: codex.path, workspace: nil)
        let memoryRoute = AgentImportRoute(source: .codex, category: .memory, root: memory.path, workspace: project.path)
        let skillRoute = AgentImportRoute(source: .codex, category: .skills, root: skills.path, workspace: nil)
        let expectedRoutes: Set<AgentImportRoute> = [route, memoryRoute, skillRoute]
        let missing = AgentImportRoute(source: .codex, category: .connectors, root: output.appendingPathComponent("Missing source").path, workspace: nil)
        let changed = memory.appendingPathComponent("changed.md")
        let publicText = Data("公开验收记忆 M-507\n".utf8), skillText = Data("---\nname: imported-public-skill\ndescription: 公开验收技能\n---\n只查看公开文件。\n".utf8)
        func write(_ value: [String: Any], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        }
        func finish() async throws {
            let end = Date().addingTimeInterval(30)
            while importer.active, Date() < end { await wait(0.05) }
            guard !importer.active else { throw PetError("混合导入仍在处理") }
        }
        var checks: [String: Bool] = [:]
        if !files.fileExists(atPath: phase.path) {
            let sessions = codex.appendingPathComponent("sessions"), skill = skills.appendingPathComponent("imported-public-skill")
            for folder in [project, memory, sessions, skill] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
            try tasks.organization.register(project.path, mode: .coding)
            for title in ["公开会话 A-102", "公开会话 B-205"] {
                let id = UUID().uuidString
                let records: [[String: Any]] = [
                    ["type": "session_meta", "payload": ["id": id, "cwd": project.path], "timestamp": "2026-11-19T01:00:00Z"],
                    ["type": "event_msg", "payload": ["type": "user_message", "message": title], "timestamp": "2026-11-19T01:00:01Z"]
                ]
                let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
                try Data((body + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
            }
            try publicText.write(to: memory.appendingPathComponent("public.md"))
            try Data("将修改的验收样例\n".utf8).write(to: changed)
            try skillText.write(to: skill.appendingPathComponent("SKILL.md"))
            await importer.detect([route, memoryRoute, missing, skillRoute])
            let tasksFound = importer.preview(for: route)?.records.filter { $0.issue == nil } ?? []
            let memories = importer.preview(for: memoryRoute)?.available ?? [], selectedSkills = importer.preview(for: skillRoute)?.available ?? []
            checks["sameScanKeepsIndependentCountsAndErrors"] = tasksFound.count == 2 && memories.count == 2 && selectedSkills.count == 1 && importer.preview(for: missing)?.issue != nil
            guard let selected = tasksFound.first(where: { $0.title == "公开会话 A-102" }) else { throw PetError("缺少公开会话") }
            let wrongTarget = AgentImportRoute(source: .codex, category: .memory, root: memory.path, workspace: nil)
            do { try importer.begin([route: [selected.id], wrongTarget: memories]); checks["batchRejectsUnscannedTarget"] = false }
            catch { checks["batchRejectsUnscannedTarget"] = importer.batch == nil }
            let wrongSource = AgentImportRoute(source: .qoder, category: .memory, root: memory.path, workspace: project.path)
            do { try importer.begin([route: [selected.id], wrongSource: memories]); checks["batchRejectsAnotherSource"] = false }
            catch { checks["batchRejectsAnotherSource"] = importer.batch == nil }
            let notify = importer.onChange
            importer.onChange = { [weak importer] in
                notify?()
                if let importer, importer.batch?.state == "running", importer.batch?.items.first?.state == "imported" { importer.pause() }
            }
            try importer.begin([route: [selected.id], memoryRoute: memories, skillRoute: selectedSkills])
            try await finish(); importer.onChange = notify
            let batch = importer.batch
            checks["oneQueueKeepsSelectionAndThreeSourceRoots"] = batch?.items.count == 4 && batch.map { value in Set(value.items.map { value.route(for: $0) }) } == expectedRoutes
            checks["pauseAfterTaskKeepsSelectedMemoryAndSkill"] = batch?.state == "paused" && batch?.items.first?.state == "imported" && batch?.items.dropFirst().allSatisfy { $0.state == "pending" } == true
            try Data("源文件在暂停后变化\n".utf8).write(to: changed)
            try publicText.write(to: memory.appendingPathComponent("after-pause.md"))
            try write(["checks": checks, "hash": binaryHash, "pid": getpid(), "taskID": selected.targetID], to: phase)
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("混合导入暂停检查未通过") }
            return
        }
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
        checks = first["checks"] as? [String: Bool] ?? [:]
        let resumed = importer.batch
        checks["freshProcessRecoversSameBatchAndScopes"] = first["hash"] as? String == binaryHash && first["pid"] as? Int != Int(getpid()) && importer.unfinished && resumed?.state == "paused" && resumed.map { value in Set(value.items.map { value.route(for: $0) }) } == expectedRoutes
        importer.resume(); try await finish()
        let items = importer.batch?.items ?? []
        checks["resumeContinuesAfterOneChangedSourceFailure"] = importer.batch?.state == "completed" && items.filter { $0.state == "imported" }.count == 3 && items.filter { $0.state == "failed" }.map(\.record.title) == ["changed.md"]
        let retainedTasks = tasks.tasks.filter { $0.importOrigin != nil }
        checks["selectedRealTaskWasImportedOnce"] = retainedTasks.count == 1 && retainedTasks.first?.id == first["taskID"] as? String && retainedTasks.first?.title == "公开会话 A-102"
        let current = try AgentMemory.importDestination(store: tasks, workspace: project.path).folder
        let global = try AgentMemory.importDestination(store: tasks, workspace: nil).folder
        let projectTopics = try files.contentsOfDirectory(atPath: current.path)
        checks["memoryKeptOriginalProjectAndFrozenSelection"] = projectTopics == ["public.md"] && !files.fileExists(atPath: global.appendingPathComponent("public.md").path)
        checks["actualProjectMemoryBytesMatch"] = try Data(contentsOf: current.appendingPathComponent("public.md")) == publicText
        if let item = items.first(where: { $0.record.category == .skills }) {
            let url = try AgentSkillImport.destinationURL(item.record, store: tasks)
            checks["actualSkillInstalledFromItsOwnDirectory"] = try Data(contentsOf: url.appendingPathComponent("SKILL.md")) == skillText
        } else { checks["actualSkillInstalledFromItsOwnDirectory"] = false }
        await importer.detect([route, memoryRoute, skillRoute])
        checks["rescanShowsAlreadyImportedAndNewSourceRecords"] = importer.preview(for: route)?.available.count == 1 && importer.preview(for: memoryRoute)?.records.count == 3 && importer.preview(for: skillRoute)?.available.isEmpty == true
        let success = checks.count == 12 && checks.values.allSatisfy { $0 }
        try write(["checks": checks, "success": success, "binaryHash": binaryHash, "appPID": getpid()], to: output.appendingPathComponent("mixed-import-report.json"))
        guard success else { throw PetError("混合导入复验失败") }
    }
}
