import AppKit

@MainActor extension AppDelegate {
    func runAgentWorkbenchCheck(_ output: URL) async {
        var report: [String: Any] = [:]
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储未初始化") }
            let data = try Data(contentsOf: output.appendingPathComponent("actual-source-report.json")), source = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard source?["success"] as? Bool == true, let live = source?["live"] as? [String: Any], let id = live["parentID"] as? String,
                  let task = tasks.task(id), task.status == .completed, !task.artifacts.isEmpty else { throw PetError("需要已完成的真实模型验收记录，不生成替代回复") }
            for metadata in tasks.tasks where metadata.id != id {
                if tasks.task(metadata.id)?.messages.isEmpty == true { tasks.update(metadata.id) { $0.archived = true } }
            }
            tasks.update(id) { $0.title = "核对角色素材" }; tasks.selectedID = id
            var p = store.preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false
            if !task.model.isEmpty { p.model = task.model }; if let context = source?["contextLimit"] as? Int { p.contextTokens = context }; if let limit = source?["outputLimit"] as? Int { p.replyTokens = limit }; store.preferences = p
            report = await control.checkWorkbench(output, actualTask: id, stoppedTask: source?["cancelledChildID"] as? String)
            var motionSequence = 0
            func recordMotion(_ trigger: String) {
                var value = control.checkWorkbenchMotion(); value["trigger"] = trigger
                try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(String(format: "workbench-motion-%03d.json", motionSequence)), options: .atomic)
                motionSequence += 1
            }
            recordMotion("initialActualSystemState")
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard self != nil else { return }; recordMotion("actualAccessibilityDisplayOptionsNotification") }
            }
            defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            report["actualModelSourceTask"] = id; report["scope"] = "Actual AppKit workbench using existing completed real-model records and actual files; no new model, microphone or TTS requests. Fixture-only title shortened; original messages and tool evidence retained. Native cacheDisplay images provide geometry diagnostics and differ from on-screen text rasterization; CUA screen captures are the primary pixel comparison evidence."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workbench-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--workbench-ui-hold") {
                try Data("ui-ready".utf8).write(to: output.appendingPathComponent("phase"), options: .atomic)
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch {
            report["error"] = error.localizedDescription; report["success"] = false
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workbench-report.json"), options: .atomic)
        }
        agentRuntime?.stopAll()
    }
}
