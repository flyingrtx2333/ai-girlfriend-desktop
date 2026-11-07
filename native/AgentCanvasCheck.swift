import AppKit
import ScreenCaptureKit

@MainActor extension AppDelegate {
    func runAgentCanvasCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "canvas-process.json")
            let nativeFile = output.appendingPathComponent("canvas-native-report.json")
            if fm.fileExists(atPath: nativeFile.path) {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeFile)) as! [String: Any]
                guard previous["success"] as? Bool == true, let values = previous["checks"] as? [String: Bool] else { throw PetError("原生画布检查未通过，不能跳过") }; checks = values
            } else {
                let id = tasks.create(title: "原生画布实际边界"), other = tasks.create(title: "另一个画布任务")
                let code = "import React from 'react'; export default function Canvas(){return <main><h1>原生画布</h1><p>public-native-canvas</p><button>真实控件</button></main>}"
                let created = try tasks.canvases.create(title: "原生边界", source: code, taskID: id), window = try await tasks.canvases.show(created.id, taskID: id), observed = try await window.inspect()
                checks["actualReactTSXRenderedInNativeWebView"] = (observed["text"] as? String)?.contains("public-native-canvas") == true && (observed["controls"] as? [[String: Any]])?.count == 1
                do { _ = try tasks.canvases.update(created.id, source: code + "\n", expected: "stale", taskID: id); checks["actualStaleHashCannotOverwriteSource"] = false } catch { checks["actualStaleHashCannotOverwriteSource"] = try tasks.canvases.source(created.id, taskID: id).code == code }
                let changed = try tasks.canvases.update(created.id, source: code.replacingOccurrences(of: "public-native-canvas", with: "public-revision-two"), expected: created.hash, taskID: id)
                _ = try tasks.canvases.restore(created.id, version: created.hash, expected: changed.hash, taskID: id)
                checks["actualVersionRestoreHasExactOriginalBytes"] = try tasks.canvases.source(created.id, taskID: id).code == code
                do { _ = try tasks.canvases.source(created.id, taskID: other); checks["anotherTaskCannotReadCanvasSource"] = false } catch { checks["anotherTaskCannotReadCanvasSource"] = true }
                guard let fork = tasks.fork(id) else { throw PetError("实际画布任务分支失败") }
                let forked = try tasks.canvases.source(created.id, taskID: fork)
                _ = try tasks.canvases.update(created.id, source: code.replacingOccurrences(of: "public-native-canvas", with: "public-fork-only"), expected: forked.record.hash, taskID: fork)
                checks["actualForkCopiesIndependentSourceAndHistory"] = try tasks.canvases.source(created.id, taskID: id).code == code && tasks.canvases.source(created.id, taskID: fork).code.contains("public-fork-only")
                let source = try tasks.canvases.sourceURL(created.id, taskID: id), files = try AgentFiles(workspace: source.deletingLastPathComponent().path)
                let external = code.replacingOccurrences(of: "public-native-canvas", with: "public-external-file-edit")
                try files.writeData(Data(external.utf8), to: source, permissions: 0o600)
                let deadline = Date().addingTimeInterval(4); var actualText = ""
                while Date() < deadline {
                    actualText = (try? await window.web.callAsyncJavaScript("return document.getElementById('canvas-root').innerText", arguments: [:], in: nil, contentWorld: .defaultClient)) as? String ?? ""
                    if actualText.contains("public-external-file-edit") { break }; await wait(0.05)
                }
                checks["actualExternalFileChangeRendersWithoutPollingService"] = actualText.contains("public-external-file-edit")
                let permissions = try fm.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
                checks["actualSourceFileIsPrivate"] = permissions == 0o600
                let reopened = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                checks["actualDiskReloadKeepsSourceAndVersions"] = try reopened.canvases.source(created.id, taskID: id).code == external && (reopened.task(id)?.canvases?.first?.versions.count ?? 0) >= 3
                let unsafe = try tasks.canvases.create(title: "未内置模块", source: "import fs from 'fs'; export default function Canvas(){return <div>{fs.readFileSync('/etc/passwd')}</div>}", taskID: id)
                let unsafeResult = try await AgentTools(store: tasks, taskID: id).execute(call("canvas_inspect", ["id": unsafe.id]))
                checks["actualModuleImportFailureKeepsEditableSource"] = unsafeResult.failed && (try? tasks.canvases.source(unsafe.id, taskID: id).code.contains("from 'fs'")) == true
                _ = try await tasks.canvases.show(created.id, taskID: id)
                let access = try await window.web.callAsyncJavaScript("return {media:typeof navigator.mediaDevices,clipboard:typeof navigator.clipboard,geolocation:typeof navigator.geolocation,popup:typeof window.open,bridge:typeof window.webkit?.messageHandlers?.bluefatfish}", arguments: [:], in: nil, contentWorld: .page) as? [String: String]
                checks["actualCanvasHasNoMediaClipboardLocationPopupOrNativeBridge"] = access?.values.allSatisfy { $0 == "undefined" } == true
                let network = try await window.web.callAsyncJavaScript("let directive='';document.addEventListener('securitypolicyviolation',e=>{directive=e.effectiveDirective},{once:true});try{await fetch('https://example.com/')}catch{} await new Promise(r=>setTimeout(r,30));return directive;", arguments: [:], in: nil, contentWorld: .page)
                checks["actualDocumentPolicyBlocksNetworkRequest"] = network as? String == "connect-src"
                let recording = CGPreflightScreenCaptureAccess(), shot = try await window.screenshot()
                checks["actualScreenshotUsesOnlyOwnWindowWithoutNewRecordingAccess"] = recording == CGPreflightScreenCaptureAccess() && shot.image.size.width > 400 && shot.capture.sourceHash == AgentFiles.hash(Data(external.utf8))
                try shot.annotationShot.png().write(to: output.appendingPathComponent("native-canvas.png"))
                let exported = try window.exportHTML(external); try exported.write(to: output.appendingPathComponent("native-export.html"))
                checks["actualExportContainsRuntimeSourceAndNoRemoteDependencies"] = exported.count > 500_000 && String(decoding: exported, as: UTF8.self).contains("public-external-file-edit")
                checks["nativeChecksDidNotCallAnyModel"] = tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty }
                try write(["success": checks.values.allSatisfy { $0 }, "checks": checks], nativeFile.lastPathComponent)
                tasks.canvases.closeAll()
            }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("原生画布检查未通过") }
            var liveID: String?, canvasID: String?
            if CommandLine.arguments.contains("--live-agent") {
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                let savedOutputLimit = preferences.outputLimit, savedContextLimit = preferences.contextLimit
                preferences.contextTokens = max(32_768, preferences.contextTokens)
                preferences.replyTokens = max(2048, preferences.replyTokens)
                report["acceptancePreferences"] = ["savedContextLimit": savedContextLimit, "actualContextLimit": preferences.contextLimit, "savedOutputLimit": savedOutputLimit, "actualOutputLimit": preferences.outputLimit, "productionSettingsWritten": false]
                preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                let owner = output.appendingPathComponent("canvas-live-task.json"), id: String
                let intent = "/canvas 读取项目sales.csv，生成可交互的销售画布，显示销售合计（两位小数）、数据行数、每项金额柱图及明细。提供‘全部’和‘仅B’两个筛选按钮，合计、行数、柱图与明细同步变化。用实际数据，完成前核对渲染，不修改原文件。以后批注应更新同一画布。"
                if fm.fileExists(atPath: owner.path) {
                    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let original = saved["taskID"], let task = tasks.task(original), task.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原真实画布任务不存在或要求变化，不替换重跑") }; id = original
                    if task.status != .completed { runtime.start(id) }
                } else {
                    let profile = AgentProfile(name: "实际画布分析", description: "只读公开数据并生成任务画布", instructions: "用实际数据生成并核对画布。先写简洁有效组件，再增量完善。", tools: ["read_file", "list_directory"] + AgentCanvas.tools, readOnly: false, network: false, enabled: true)
                    let (_, version) = try tasks.agents.document(), values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try tasks.agents.list() + [profile]))
                    try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: version)
                    id = try tasks.agents.createTask(profile.id, store: tasks, workspace: output.appendingPathComponent("repo").path)
                    tasks.update(id) { $0.title = "实际销售交互画布" }
                    guard runtime.submit(intent, taskID: id) else { throw PetError("真实画布任务未开始") }
                    try write(["taskID": id, "originalInputID": tasks.task(id)?.messages.first(where: \.isHumanInput)?.id ?? ""], owner.lastPathComponent)
                }
                liveID = id; control.showAgentTask(id); control.show(tab: "chat")
                var approvals = 0
                func approve() throws {
                    guard let task = tasks.task(id), task.status == .waiting, let call = task.pendingCalls.first else { return }
                    let allowed = AgentCanvas.writes.contains(call.name) && (call.name == "canvas_create" ? (task.canvases ?? []).isEmpty : task.canvases?.first?.id == call.object["id"] as? String)
                    guard allowed, approvals < 16 else { throw PetError("真实模型提出预期外画布审批") }
                    runtime.decide(taskID: id, callID: call.id, decision: "allow"); approvals += 1
                }
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    try approve(); let task = tasks.task(id)!
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实画布任务未完成：" + (task.events.last?.detail ?? "")) }; await wait(0.05)
                }
                let task = tasks.task(id)!
                guard task.status == .completed, let first = task.canvases?.first else { throw PetError("真实模型未完成画布") }
                canvasID = first.id; let window = try await tasks.canvases.show(first.id, taskID: id), rendered = try await window.inspect()
                checks["realModelUsesActualCsvAndRenderedCanvas"] = (rendered["text"] as? String)?.contains("49.00") == true && (rendered["svg_count"] as? Int ?? 0) > 0
                checks["realModelDidNotModifyInputOrUseExternalTools"] = task.messages.flatMap { $0.toolCalls ?? [] }.allSatisfy { (["load_tools", "read_file", "list_directory", "read_task_history", "update_plan"] + AgentCanvas.tools).contains($0.name) }
                report["live"] = ["taskID": id, "canvasID": first.id, "sourceHash": first.hash, "rendered": rendered, "model": preferences.model, "contextLimit": preferences.contextLimit, "outputLimit": preferences.outputLimit, "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "approvals": task.approvals.filter { $0.decision == "allow" }.count]
                try write(["taskID": id, "canvasID": first.id, "sourceHash": first.hash, "appPID": getpid()], "canvas-ui-ready.json")
                report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; try write(report, "canvas-report.json")
                if CommandLine.arguments.contains("--hold-ui") {
                    let deadline = Date().addingTimeInterval(1200)
                    while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-canvas-ui").path) { try approve(); await wait(0.1) }
                }
            }
            if let id = liveID, let canvasID {
                let task = tasks.task(id)!, source = try tasks.canvases.source(canvasID, taskID: id), window = try await tasks.canvases.show(canvasID, taskID: id)
                try window.exportHTML(source.code).write(to: output.appendingPathComponent("actual-model-canvas.html"))
                try Data(source.code.utf8).write(to: output.appendingPathComponent("actual-model.canvas.tsx"))
                report["afterUI"] = ["sourceHash": source.record.hash, "rendered": try await window.inspect(), "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "approvals": task.approvals.filter { $0.decision == "allow" }.count]
            }
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; try write(report, "canvas-report.json")
            tasks.canvases.closeAll(); runtime.stopAll()
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "canvas-report.json"); agentRuntime?.stopAll() }
    }
}
