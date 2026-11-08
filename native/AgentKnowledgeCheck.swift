import AppKit

@MainActor extension AppDelegate {
    func runAgentKnowledgeCheck(_ output: URL) async {
        let fm = FileManager.default
        var report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("知识库运行时未初始化") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash], "knowledge-process.json")
            guard let arg = CommandLine.arguments.firstIndex(of: "--knowledge-source"), CommandLine.arguments.indices.contains(arg + 1) else { throw PetError("缺少真实来源清单") }
            let manifest = URL(fileURLWithPath: CommandLine.arguments[arg + 1]), original = try Data(contentsOf: manifest), originalHash = AgentFiles.hash(original)
            let nativeURL = output.appendingPathComponent("knowledge-native-" + String(hash.prefix(12)) + ".json")
            if !fm.fileExists(atPath: nativeURL.path) {
                let nativeRoot = output.appendingPathComponent("native-" + String(hash.prefix(12)), isDirectory: true)
                try fm.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
                let profile = nativeRoot.appendingPathComponent("native-library-profile"), isolated = AgentStore(directory: profile, legacy: [], extensionHome: nativeRoot.appendingPathComponent("shared-home"))
                let library = isolated.knowledge
                var checks: [String: Bool] = [:]
                checks["emptyReadDoesNotCreateCatalog"] = try library.document().0.bases.isEmpty && !fm.fileExists(atPath: library.directory.path)
                let workspace = nativeRoot.appendingPathComponent("library-workspace"), other = nativeRoot.appendingPathComponent("other-workspace")
                for path in [workspace, other] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
                let global = try library.create(name: "依赖核对", workspace: nil), scoped = try library.create(name: "当前项目资料", workspace: workspace.path)
                let source = try await library.add(manifest, baseID: global.id), privateSource = try await library.add(manifest, baseID: scoped.id)
                let asking = isolated.create(workspace: nil, mode: .ask), project = isolated.create(workspace: workspace.path, mode: .ask), unrelated = isolated.create(workspace: other.path, mode: .plan)
                func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) async throws -> AgentToolResult {
                    let value = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
                    let tools = AgentTools(store: isolated, taskID: id); _ = try tools.approvalReason(for: value); return try await tools.execute(value)
                }
                checks["userAndWorkspaceEffectiveScopes"] = try library.available(isolated.task(asking)!).map(\.id) == [global.id] && library.available(isolated.task(project)!).count == 2 && library.available(isolated.task(unrelated)!).map(\.id) == [global.id]
                let result = try await call(asking, "read_knowledge", ["id": source.id])
                checks["askWithoutWorkspaceReadsActualImportedSource"] = !result.failed && result.text.contains(originalHash) && result.text.contains("runtime")
                let searched = try await call(asking, "search_knowledge", ["query": "libraries"])
                checks["searchReturnsActualLinesAndSourceHash"] = searched.text.contains(source.id) && searched.text.contains(originalHash) && searched.text.contains("libraries")
                do { _ = try await call(asking, "read_knowledge", ["id": privateSource.id]); checks["guessedOtherWorkspaceSourceIsRejected"] = false } catch { checks["guessedOtherWorkspaceSourceIsRejected"] = true }
                do { _ = try await call(unrelated, "list_knowledge", ["base_id": scoped.id]); checks["otherWorkspaceCatalogIsRejected"] = false } catch { checks["otherWorkspaceCatalogIsRejected"] = true }
                let copyURL = try library.sourceURL(source)
                checks["sourceCopyAndOriginalBytesMatch"] = try Data(contentsOf: copyURL) == original && Data(contentsOf: manifest) == original
                let before = try library.document().1
                try library.rename(global.id, name: "依赖资料", expected: before)
                do { try library.rename(global.id, name: "过期覆盖", expected: before); checks["staleCatalogCannotOverwriteChanges"] = false } catch { checks["staleCatalogCannotOverwriteChanges"] = true }
                try library.archive(source: source.id, archived: true, expected: library.document().1)
                do { _ = try await call(asking, "read_knowledge", ["id": source.id]); checks["removedFileIsUnavailableButRecoverable"] = false } catch { checks["removedFileIsUnavailableButRecoverable"] = fm.fileExists(atPath: copyURL.path) }
                try library.archive(source: source.id, archived: false, expected: library.document().1)
                checks["restoreFilePreservesExactBytes"] = try Data(contentsOf: library.sourceURL(source)) == original
                let replacement = nativeRoot.appendingPathComponent("replacement/manifest.json"); try fm.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
                var changedManifest = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                changedManifest["knowledge_revision"] = 2
                let replacementBytes = try JSONSerialization.data(withJSONObject: changedManifest, options: [.prettyPrinted, .sortedKeys])
                try replacementBytes.write(to: replacement)
                let replaced = try await library.add(replacement, baseID: global.id, replacing: source.id)
                let afterReplacement = try library.document().0
                checks["replacementRetainsOriginalVersionAndNewBytes"] = try afterReplacement.sources.first(where: { $0.id == source.id })?.archived == true && Data(contentsOf: library.sourceURL(replaced)) == replacementBytes && Data(contentsOf: copyURL) == original
                let exported = nativeRoot.appendingPathComponent("downloaded-reference.json")
                try await library.export(replaced, to: exported)
                checks["coordinatedDownloadCreatesExactFile"] = try Data(contentsOf: exported) == replacementBytes
                try Data("existing public download".utf8).write(to: exported, options: .atomic)
                try await library.export(replaced, to: exported)
                checks["coordinatedDownloadReplacesSelectedFile"] = try Data(contentsOf: exported) == replacementBytes
                let outputLink = nativeRoot.appendingPathComponent("download-link.json"); try fm.createSymbolicLink(at: outputLink, withDestinationURL: manifest)
                do { try await library.export(replaced, to: outputLink); checks["downloadDoesNotOverwriteLinkTarget"] = false } catch { checks["downloadDoesNotOverwriteLinkTarget"] = try Data(contentsOf: manifest) == original }
                try library.archive(base: global.id, archived: true, expected: library.document().1)
                checks["removedLibraryDisappearsFromTaskScope"] = try library.available(isolated.task(asking)!).isEmpty
                try library.archive(base: global.id, archived: false, expected: library.document().1)
                let reloaded = AgentKnowledgeLibrary(profile: profile)
                checks["catalogAndImportedDataSurviveReload"] = try reloaded.available(isolated.task(asking)!).first?.id == global.id && reloaded.content(replaced).parts.first?.text.contains("runtime") == true
                let cache = try library.sourceURL(replaced).deletingLastPathComponent().appendingPathComponent("content.json"), goodCache = try Data(contentsOf: cache)
                try Data("{}".utf8).write(to: cache, options: .atomic)
                do { _ = try library.content(replaced); checks["modifiedExtractionIsRejected"] = false } catch { checks["modifiedExtractionIsRejected"] = true }
                try goodCache.write(to: cache, options: .atomic)
                let replacedURL = try library.sourceURL(replaced), goodSource = try Data(contentsOf: replacedURL)
                try Data("external change".utf8).write(to: replacedURL, options: .atomic)
                do { _ = try library.sourceURL(replaced); checks["modifiedOriginalCopyIsRejected"] = false } catch { checks["modifiedOriginalCopyIsRejected"] = true }
                try Data("keep selected output".utf8).write(to: exported, options: .atomic)
                do { try await library.export(replaced, to: exported); checks["invalidSourceLeavesSelectedOutputUntouched"] = false } catch { checks["invalidSourceLeavesSelectedOutputUntouched"] = try Data(contentsOf: exported) == Data("keep selected output".utf8) }
                try goodSource.write(to: replacedURL, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: replacedURL.path)
                let originalFolder = copyURL.deletingLastPathComponent(), held = nativeRoot.appendingPathComponent("held-source")
                try fm.moveItem(at: originalFolder, to: held); try fm.createSymbolicLink(at: originalFolder, withDestinationURL: held)
                do { _ = try library.sourceURL(source); checks["sourceDirectoryLinkCannotEscapeLibrary"] = false } catch { checks["sourceDirectoryLinkCannotEscapeLibrary"] = true }
                try fm.removeItem(at: originalFolder); try fm.moveItem(at: held, to: originalFolder)
                let link = nativeRoot.appendingPathComponent("linked-manifest.json"); try fm.createSymbolicLink(at: link, withDestinationURL: manifest)
                do { _ = try await library.add(link, baseID: global.id); checks["symbolicLinkImportIsRejected"] = false } catch { checks["symbolicLinkImportIsRejected"] = error.localizedDescription.contains("普通文件") }
                let huge = nativeRoot.appendingPathComponent("too-large.pdf"); fm.createFile(atPath: huge.path, contents: nil)
                let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 150_000_001); try handle.close()
                do { _ = try await library.add(huge, baseID: global.id); checks["oversizedSourceIsRejectedBeforeParsing"] = false } catch { checks["oversizedSourceIsRejectedBeforeParsing"] = error.localizedDescription.contains("大小上限") }
                try fm.removeItem(at: huge)
                let long = nativeRoot.appendingPathComponent("long-reference.txt"), text = String(repeating: "长段资料-2086 ", count: 130_000)
                try Data(text.utf8).write(to: long)
                let large = try await library.add(long, baseID: global.id), first = try await call(asking, "read_knowledge", ["id": large.id, "lines": 1])
                let firstObject = try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as! [String: Any]
                let next = try await call(asking, "read_knowledge", ["id": large.id, "lines": 1, "content_offset": firstObject["next_content_offset"] as? Int ?? 0])
                let largeContent = try library.content(large)
                checks["largeTextIsBoundedAndLongLinesCanContinue"] = large.file.partial && firstObject["next_content_offset"] as? Int == 24_000 && next.text.contains("24000") && (largeContent.parts.first?.text.count ?? 0) <= 500_000
                let attachment = try await AgentAttachments.importFile(manifest, store: isolated, taskID: asking, draft: false)
                checks["ordinaryAttachmentImportStillReadsOriginalBytes"] = try AgentAttachments.content(store: isolated, taskID: asking, id: attachment.id).parts.first?.text == String(decoding: original, as: UTF8.self)
                let tools = AgentTools.definitions(mode: .ask, groups: ["knowledge"]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                checks["askToolCatalogIncludesKnowledgeReadTools"] = Set(AgentKnowledgeLibrary.tools).isSubset(of: Set(tools))
                let mode = (try fm.attributesOfItem(atPath: library.directory.path)[.posixPermissions]) as? Int
                let catalogMode = try fm.attributesOfItem(atPath: library.directory.appendingPathComponent("catalog.json").path)[.posixPermissions] as? Int
                checks["catalogHasPrivatePermissions"] = mode == 0o700 && catalogMode == 0o600
                let success = checks.values.allSatisfy { $0 }
                try write(["success": success, "binaryHash": hash, "checks": checks, "sourceHash": originalHash], nativeURL.lastPathComponent)
                guard success else { throw PetError("知识库检查失败：" + checks.filter { !$0.value }.map(\.key).joined(separator: "、")) }
            }
            let native = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeURL)) as! [String: Any]
            guard native["success"] as? Bool == true, CommandLine.arguments.contains("--live-agent") else { throw PetError("需要通过原生检查及真实模型验收") }
            let production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
            store.preferences = preferences; try store.savePreferences()
            let ownerURL = output.appendingPathComponent("knowledge-owner.json"), id: String
            if let bytes = try? Data(contentsOf: ownerURL), let owner = try JSONSerialization.jsonObject(with: bytes) as? [String: String], let existing = owner["id"], tasks.task(existing) != nil { id = existing }
            else { id = tasks.create(title: "知识库依赖核对", workspace: nil, mode: .ask); try write(["id": id], ownerURL.lastPathComponent) }
            control.showAgentTask(id); control.show(tab: "chat")
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": id, "model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "manifest": manifest.path, "sourceHash": originalHash], "knowledge-ui-ready.json")
            let deadline = Date().addingTimeInterval(1800)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-knowledge-ui").path) {
                if let task = tasks.task(id), (task.modelReceipts?.count ?? 0) > 12, task.status != .completed { runtime.cancel(id); throw PetError("知识库验收超过12份实际请求，原任务保留") }
                await wait(0.2)
            }
            guard fm.fileExists(atPath: output.appendingPathComponent("finish-knowledge-ui").path), let task = tasks.task(id), task.mode == .ask, task.workspace == nil, task.status == .completed, !runtime.isExecuting(id) else { throw PetError("原知识库任务尚未完成，保留记录") }
            let calls = Dictionary(task.messages.flatMap { ($0.toolCalls ?? []).map { ($0.id, $0) } }, uniquingKeysWith: { _, last in last })
            let reads = task.messages.filter { message in message.role == "tool" && calls[message.toolCallID ?? ""]?.name == "read_knowledge" && task.events.contains(where: { $0.toolCallID == message.toolCallID && $0.status == "completed" }) }
            guard reads.contains(where: { $0.content.contains(originalHash) }) else { throw PetError("模型未实际读取导入的真实清单") }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("knowledge-ui-acceptance.json"))) as! [String: Any]
            guard ui["appPID"] as? Int == Int(getpid()), ui["binaryHash"] as? String == hash, let checks = ui["checks"] as? [String: Bool], ["createAndImportActualSource", "sourcePreviewAndDownload", "scopeAndRecoveryControls", "realModelReadAndAnswer"].allSatisfy({ checks[$0] == true }) else { throw PetError("知识库实际窗口验收记录不匹配") }
            report = ["success": true, "taskID": id, "binaryHash": hash, "native": native, "ui": ui, "sourceHash": originalHash, "reply": task.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.content ?? "", "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens]
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        try? write(report, "knowledge-report.json")
    }
}
