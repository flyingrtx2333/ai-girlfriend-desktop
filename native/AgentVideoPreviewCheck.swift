import AppKit

@MainActor extension AppDelegate {
    func runAgentVideoPreviewCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("视频验收只播放实际文件，不调用模型") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            let origin = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("media-origin.json"))) as! [String: Any]
            let entries = origin["files"] as! [[String: Any]], mp4 = try files.resolve("media/flower.mp4"), webm = try files.resolve("media/flower.webm")
            var hashes: [String: String] = [:]
            for entry in entries {
                let path = "media/" + (entry["name"] as! String), hash = try files.fileHash(files.resolve(path)); hashes[path] = hash
                guard hash == entry["sha256"] as? String else { throw PetError("实际视频与来源哈希不一致") }
            }
            checks["realMP4AndWebMMatchIndependentSourceHashes"] = hashes.count == 2
            let pinned = try AgentVideoSnapshot.create(files: files, file: mp4), snapshots = try AgentFiles(workspace: pinned.folder.path)
            checks["snapshotRetainsExactOriginalMP4BytesAndReadOnlyPermissions"] = try pinned.hash == hashes["media/flower.mp4"] && snapshots.fileHash(pinned.media) == pinned.hash && snapshots.entryMetadata(pinned.media).permissions == 0o400
            let shell = try String(contentsOf: pinned.document, encoding: .utf8)
            checks["playerHasLocalControlsAndNoAutoplayNativeBridgeOrNetworkPermission"] = shell.contains(" controls ") && !shell.contains("autoplay") && shell.contains("connect-src 'none'") && shell.contains("frame-src 'none'") && shell.contains("form-action 'none'") && !shell.contains("messageHandlers") && shell.contains("visibilitychange")
            try fm.removeItem(at: pinned.folder)
            checks["closedSnapshotDirectoryRemoved"] = !fm.fileExists(atPath: pinned.folder.path)
            let outside = output.appendingPathComponent("outside.mp4"); try files.readData(mp4, maximum: 2_000_000).write(to: outside)
            let alias = workspace.appendingPathComponent("outside-link.mp4"); try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
            let secret = try files.resolve(".env.preview/secret.mp4"); try files.writeData(files.readData(mp4, maximum: 2_000_000), to: secret)
            let wrong = try files.resolve("media/flower.mov"); try files.writeData(files.readData(mp4, maximum: 2_000_000), to: wrong)
            let large = try files.resolve("too-large.mp4"); try files.writeData(Data(), to: large)
            let sparse = try FileHandle(forWritingTo: large); try sparse.truncate(atOffset: UInt64(AgentVideoSnapshot.maximum + 1)); try sparse.close()
            for (name, file) in [("outsideWorkspace", outside), ("symlinkOutsideWorkspace", alias), ("sensitiveParent", secret), ("unsupportedExtension", wrong), ("directoryDisguisedAsVideo", workspace.appendingPathComponent("directory.mp4")), ("oversizedVideo", large)] {
                if name == "directoryDisguisedAsVideo" { try fm.createDirectory(at: file, withIntermediateDirectories: false) }
                do { let accidental = try AgentVideoSnapshot.create(files: files, file: file); try? fm.removeItem(at: accidental.folder); checks[name + "Rejected"] = false }
                catch { checks[name + "Rejected"] = true }
            }
            report["oversizedGuardActualBytes"] = (try large.resourceValues(forKeys: [.fileSizeKey])).fileSize
            try files.remove(large)
            let broken = try files.resolve("media/broken.mp4"), guide = try files.resolve("docs/VIDEO.md")
            try files.writeData(Data(files.readData(mp4, maximum: 2_000_000).prefix(128)), to: broken)
            let guideText = try String(contentsOf: guide, encoding: .utf8); hashes["docs/VIDEO.md"] = try files.fileHash(guide); hashes["media/broken.mp4"] = try files.fileHash(broken)
            checks["realProjectGuideContainsScopedVideoLinks"] = guideText.contains("../media/flower.mp4") && guideText.contains("../media/flower.webm")
            ensureAgent(); guard let tasks = agentStore else { throw PetError("视频任务未初始化") }; _ = control
            let id = tasks.create(title: "视频产物预览", workspace: workspace.path, mode: .ask)
            tasks.update(id) { $0.artifacts = [mp4.path, webm.path, broken.path, guide.path]; $0.sources = [webm.absoluteString]; $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .agent); tasks.update(other) { $0.draft = "保留的B草稿" }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 1, value: mp4.path) else { throw PetError("视频记录窗口未打开") }
            var initial: [String: Any] = [:]
            for _ in 0..<80 {
                initial = await records.videoPreviewReadback()
                if let player = initial["player"] as? [String: Any], (player["readyState"] as? Int ?? 0) > 0 || (player["error"] as? Int ?? 0) > 0 { break }
                await wait(0.25)
            }
            let player = initial["player"] as? [String: Any] ?? [:]
            let expectedMP4 = entries.first { $0["name"] as? String == "flower.mp4" }!
            checks["actualMP4MetadataMatchesIndependentFFprobe"] = (player["readyState"] as? Int ?? 0) > 0 && abs((player["duration"] as? Double ?? 0) - (expectedMP4["duration"] as! Double)) < 0.15 && player["width"] as? Int == 960 && player["height"] as? Int == 540
            checks["askModeVideoIsPausedAndReadOnly"] = player["paused"] as? Bool == true && player["controls"] as? Bool == true && initial["saveVisible"] as? Bool == false && initial["compareVisible"] as? Bool == false && initial["textEditable"] as? Bool == false
            checks["initialVideoHasActualVisiblePlayerArea"] = (player["clientWidth"] as? Int ?? 0) >= 400 && (player["clientHeight"] as? Int ?? 0) >= 200
            try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("native-video-initial.json"))
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("播放前的原生检查未通过") }
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID":ProcessInfo.processInfo.processIdentifier,"binaryHash":binaryHash,"taskID":id,"otherTaskID":other,"workspace":workspace.path,"files":hashes,"checks":checks,"modelsCalled":false]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("video-preview-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-video-preview-ui").path) {
                if let request = try? String(contentsOf: output.appendingPathComponent("capture-video-state"), encoding: .utf8), request != capture, request.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = request; var state = await records.videoPreviewReadback(); state["appPID"] = ProcessInfo.processInfo.processIdentifier
                    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("native-video-" + capture + ".json"))
                }
                await wait(0.25)
            }
            if let bytes = try? Data(contentsOf: output.appendingPathComponent("video-preview-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            var unchanged = true
            for (name, hash) in hashes { unchanged = try unchanged && files.fileHash(files.resolve(name)) == hash }; checks["allOpenedProjectFilesUnchanged"] = unchanged
            checks["bothTaskComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }; checks["noModelsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash; report["originalFileHashes"] = hashes
            records.close()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("video-preview-report.json"))
    }
}
