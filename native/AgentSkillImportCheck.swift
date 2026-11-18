import AppKit

@MainActor extension AppDelegate {
    func runSkillImportCheck(_ output: URL) async {
        let phase = output.appendingPathComponent("skill-import-paused.json")
        let report = output.appendingPathComponent("skill-import-report.json")
        let fm = FileManager.default
        let home = output.appendingPathComponent("shared-home")
        let modern = output.appendingPathComponent("export-modern/.agents/skills")
        let legacy = output.appendingPathComponent("export/.codex")
        let project = output.appendingPathComponent("harbor")
        let other = output.appendingPathComponent("lighthouse")
        let scriptsMarker = output.appendingPathComponent("unexpected-script-output")
        let sampleAsset = Data([0, 1, 2, 0xFF, 0xC2])
        let sampleText = "PUBLIC-SKILL · 实际资源内容 🐳"
        let store = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: home)
        let service = store.dataImport, library = store.extensions
        var checks: [String: Bool] = [:]

        func write(_ data: Data, at file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        func save(_ value: [String: Any], to file: URL) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), at: file)
        }
        func skill(_ name: String, at folder: URL, body: String = "公开工作流程。") throws {
            try write(Data("---\nname: \(name)\ndescription: 公共验收样例\n---\n\n\(body)\n".utf8), at: folder.appendingPathComponent("SKILL.md"))
        }
        func untilIdle() async throws {
            let deadline = Date().addingTimeInterval(25)
            while service.active && Date() < deadline { await wait(0.04) }
            guard !service.active else { throw PetError("Skill 导入仍在运行") }
        }
        func call(_ name: String, _ args: [String: String] = [:]) throws -> AgentToolCall {
            let data = try JSONSerialization.data(withJSONObject: args)
            return AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self))
        }
        do {
            if !fm.fileExists(atPath: phase.path) {
                let first = modern.appendingPathComponent("asset-check")
                try skill("asset-check", at: first)
                try write(sampleAsset, at: first.appendingPathComponent("assets/nested/sample.bin"))
                try write(Data(sampleText.utf8), at: first.appendingPathComponent("references/nested/notes.md"))
                try write(Data("#!/bin/sh\ntouch \(AgentGit.quote(scriptsMarker.path))\n".utf8), at: first.appendingPathComponent("scripts/sample.sh"))
                try write(Data("TEST-METADATA".utf8), at: first.appendingPathComponent(".env"))
                try skill("readback", at: modern.appendingPathComponent("readback"))
                try skill("system-fixture", at: modern.appendingPathComponent(".system/system-fixture"))
                await service.detect(.codex, root: modern, category: .skills)
                let ready = service.preview.filter { $0.issue == nil }
                checks["codexPackagesCanBeCopiedIntoManagedScope"] = Set(ready.map(\.title)) == ["asset-check", "readback"] && service.preview.count == 2
                checks["previewCountsPackagedResourceFilesOnly"] = ready.first { $0.title == "asset-check" }?.skill?.fileCount == 4
                service.onChange = { [weak service] in
                    if service?.batch?.state == "running", service?.batch?.items.filter({ $0.state == "imported" }).count == 1 {
                        service?.pause()
                    }
                }
                try service.begin(.codex, root: modern, ids: Set(ready.map(\.id)), category: .skills)
                try await untilIdle()
                service.onChange = nil
                guard let batch = service.batch, let done = batch.items.first(where: { $0.state == "imported" }),
                      let pending = batch.items.first(where: { $0.state == "pending" }) else { throw PetError("未取得暂停后的 Skill 批次") }
                checks["firstPackagePublishedBeforePause"] = batch.state == "paused" && batch.items.count == 2 && done.record.title == "asset-check"
                let installed = try AgentSkillImport.destinationURL(done.record, store: store)
                checks["definitionAndNestedBinaryAreByteExact"] = try Data(contentsOf: installed.appendingPathComponent("SKILL.md")) == Data(contentsOf: first.appendingPathComponent("SKILL.md"))
                    && Data(contentsOf: installed.appendingPathComponent("assets/nested/sample.bin")) == sampleAsset
                let installedFiles = try AgentFiles(workspace: installed.path)
                checks["noHiddenMetadataOrScriptExecution"] = !fm.fileExists(atPath: scriptsMarker.path) && !fm.fileExists(atPath: installed.appendingPathComponent(".env").path)
                checks["scriptUsesExistingPrivateFilePermissions"] = try installedFiles.entryMetadata(installed.appendingPathComponent("scripts/sample.sh")).permissions == 0o600
                // Simulates a completed copy whose status could not be saved before exit.
                try await AgentSkillImport.install(pending.record, root: modern, store: store)
                let file = try AgentSkillImport.destinationURL(pending.record, store: store).appendingPathComponent("SKILL.md")
                let files = try AgentFiles(workspace: library.profile.path)
                let signature = try files.entryMetadata(file).signature
                let pendingSource = URL(fileURLWithPath: pending.record.file).deletingLastPathComponent()
                try fm.moveItem(at: pendingSource, to: output.appendingPathComponent("temporarily-removed-source"))
                try skill("added-after-pause", at: modern.appendingPathComponent("added-after-pause"))
                try save(["batch": batch.id, "checks": checks, "file": file.path, "signature": signature, "pid": getpid()], to: phase)
                return
            }

            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as! [String: Any]
            checks = seed["checks"] as! [String: Bool]
            checks["pauseRestoresOriginalCategoryAndScopeInAnotherProcess"] = service.batch?.id == seed["batch"] as? String
                && seed["pid"] as? Int != Int(getpid()) && service.batch?.category == .skills && service.batch?.targetWorkspace == nil
                && service.batch?.state == "paused" && service.unfinished
            service.resume(); try await untilIdle()
            checks["resumeAppliesOnlyOriginalSelection"] = service.batch?.state == "completed" && service.batch?.items.count == 2
                && service.batch?.items.allSatisfy { $0.state == "imported" } == true
            let files = try AgentFiles(workspace: library.profile.path), file = URL(fileURLWithPath: seed["file"] as! String)
            checks["resumeKeepsAlreadyPublishedFileUnchanged"] = try files.entryMetadata(file).signature == seed["signature"] as? String
            try fm.moveItem(at: output.appendingPathComponent("temporarily-removed-source"), to: modern.appendingPathComponent("readback"))
            await service.detect(.codex, root: modern, category: .skills)
            checks["rescanSkipsIdenticalTargets"] = service.preview.filter { $0.issue == "已经导入" }.count == 2
                && service.preview.filter { $0.issue == nil }.map(\.title) == ["added-after-pause"]
            guard let imported = service.preview.first(where: { $0.title == "asset-check" }) else { throw PetError("未找到已导入的 Skill") }
            let package = try AgentSkillImport.read(imported, root: modern), installed = try AgentSkillImport.destinationURL(imported, store: store)
            do {
                try package.publish(to: installed, files: files)
                checks["publicationWillNotReplaceExistingDirectory"] = false
            } catch {
                checks["publicationWillNotReplaceExistingDirectory"] = try AgentExtensions.digest(AgentExtensions.resourceData(AgentFiles(workspace: installed.path))) == imported.sourceHash
                    && !fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path).contains { $0.hasPrefix(".skill-import-") }
            }
            try skill("legacy-notes", at: legacy.appendingPathComponent("skills/legacy-notes"))
            try write(Data("PUBLIC-FIXTURE-CREDENTIAL-METADATA".utf8), at: legacy.appendingPathComponent("auth.json"))
            await service.detect(.codex, root: legacy, category: .skills)
            checks["legacyCodexDirectoryFindsOnlySkillPackages"] = service.preview.map(\.title) == ["legacy-notes"] && service.preview.first?.issue == nil
            let single = try await library.importItem(legacy.appendingPathComponent("skills/legacy-notes"), kind: .skill, project: false, workspace: nil)
            checks["directSkillImportStillReturnsManagedItem"] = single.managed && single.scope == "全局" && single.name == "legacy-notes"
            let shared = home.appendingPathComponent(".agents/skills")
            try skill("shared-notes", at: shared.appendingPathComponent("shared-notes"))
            guard let sharedItem = try library.catalog(workspace: nil).first(where: { $0.name == "shared-notes" }) else {
                throw PetError("共享 Skill 未加入目录")
            }
            try library.setEnabled(sharedItem, enabled: false, workspace: nil)
            await service.detect(.codex, root: shared, category: .skills)
            let existing = try library.item(sharedItem.id, workspace: nil, enabled: false)
            checks["sharedSkillKeepsExistingIdentityAndDisabledState"] = service.preview.first?.issue == "已由共享目录提供"
                && !existing.enabled && !existing.managed
            let qoderRoot = output.appendingPathComponent("qoder-export")
            let qoder = qoderRoot.appendingPathComponent(".qoder/skills")
            let chosen = qoder.appendingPathComponent("project-brief")
            let changing = qoder.appendingPathComponent("updated-source")
            try skill("project-brief", at: chosen)
            try write(Data(sampleText.utf8), at: chosen.appendingPathComponent("reference.md"))
            try skill("updated-source", at: changing)
            let change = changing.appendingPathComponent("reference.md")
            try write(Data("最初版本".utf8), at: change)
            try skill("target-conflict", at: qoder.appendingPathComponent("target-conflict"))
            try skill("dupe", at: qoder.appendingPathComponent("dupe-a"))
            try skill("DUPE", at: qoder.appendingPathComponent("dupe-b"))
            let linked = qoder.appendingPathComponent("linked")
            try skill("linked", at: linked)
            try fm.createSymbolicLink(at: linked.appendingPathComponent("public-link.md"), withDestinationURL: change)
            for directory in [project, other] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            try store.organization.register(project.path, mode: .coding)
            try store.organization.register(other.path, mode: .general)
            await service.detect(.qoder, root: qoderRoot, category: .skills, workspace: project.path)
            let preview = service.preview
            let ready = Set(preview.filter { $0.issue == nil }.map(\.id))
            checks["qoderProjectPreviewFindsCompatiblePackages"] = ready.count == 3 && preview.first { $0.title == "project-brief" }?.targetWorkspace == project.path
            checks["duplicateSourcesAndLinkedResourcesAreReported"] = preview.filter { $0.issue?.contains("多份同名") == true }.count == 2
                && preview.first { $0.title == "linked" }?.issue?.contains("符号链接") == true
            do {
                try service.begin(.qoder, root: qoderRoot, ids: ready, category: .skills, workspace: other.path)
                checks["startCannotSubstituteAnotherProject"] = false
            } catch { checks["startCannotSubstituteAnotherProject"] = error.localizedDescription.contains("重新检测") }
            try write(Data("更新且保留".utf8), at: change)
            let conflict = project.appendingPathComponent(".bluefatfish/skills/target-conflict")
            try skill("target-conflict", at: conflict, body: "本地改动保留。")
            let original = try Data(contentsOf: conflict.appendingPathComponent("SKILL.md"))
            try service.begin(.qoder, root: qoderRoot, ids: ready, category: .skills, workspace: project.path)
            try await untilIdle()
            let items = service.batch?.items ?? []
            checks["changedResourceBlocksOnlyThatPackage"] = items.first { $0.record.title == "updated-source" }?.detail.contains("资源已变化") == true
                && !fm.fileExists(atPath: project.appendingPathComponent(".bluefatfish/skills/updated-source").path)
                && items.first { $0.record.title == "project-brief" }?.state == "imported"
            checks["newTargetConflictPreservesLocalBytes"] = try Data(contentsOf: conflict.appendingPathComponent("SKILL.md")) == original
                && items.first { $0.record.title == "target-conflict" }?.state == "failed"
            let managed = try library.catalog(workspace: project.path).first { $0.name == "project-brief" }
            checks["projectImportUsesOnlyChosenScope"] = managed?.managed == true && managed?.scope == "项目"
                && !fm.fileExists(atPath: other.appendingPathComponent(".bluefatfish").path)
                && !fm.fileExists(atPath: library.profile.appendingPathComponent("extensions/skills/project-brief").path)
            guard let managed else { throw PetError("从扩展目录读回项目 Skill 失败") }
            let id = store.create(title: "公开项目样例", workspace: project.path)
            let foreign = store.create(title: "其他项目样例", workspace: other.path)
            let tools = AgentTools(store: store, taskID: id)
            let found = try await tools.execute(call("list_skills", ["query": "project-brief"]))
            let loaded = try await tools.execute(call("read_skill", ["id": managed.id]))
            let read = try await tools.execute(call("read_skill_resource", ["id": managed.id, "path": "reference.md"]))
            let outside = try await AgentTools(store: store, taskID: foreign).execute(call("list_skills", ["query": "project-brief"]))
            checks["normalToolFlowReadsManagedSkillAndNestedResources"] = found.text.contains(managed.id) && loaded.text.contains("公开工作流程")
                && read.text.contains(sampleText) && !outside.text.contains(managed.id)
            let currentSource = try Data(contentsOf: chosen.appendingPathComponent("reference.md"))
            checks["sourceAssetsAndScriptsStayUntouched"] = currentSource == Data(sampleText.utf8) && !fm.fileExists(atPath: scriptsMarker.path)
                && fm.fileExists(atPath: modern.appendingPathComponent("asset-check/.env").path)
            try save(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": 0], to: report)
        } catch {
            try? save(["success": false, "checks": checks, "error": error.localizedDescription, "pid": getpid(), "modelRequests": 0], to: report)
        }
    }
}
