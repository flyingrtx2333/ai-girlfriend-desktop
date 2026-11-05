import AppKit
import AVFAudio

@MainActor extension AppDelegate {
    func runConversationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        store.messages = [ChatMessage(role: "user", content: "周末想出去走走，你有什么建议？"),
            ChatMessage(role: "assistant", content: "找个有树荫的公园，慢慢走一圈吧。路上买杯喜欢的饮料，看到好看的花就停下来看看。\n\n不用把行程排满，留点时间发呆也很好。"),
            ChatMessage(role: "user", content: "如果下雨呢？"),
            ChatMessage(role: "assistant", content: "那就把散步换成逛书店，找个靠窗的位置坐一会儿。带上耳机，听听雨声，周末也可以过得很舒服。")]
        let layout = await control.checkLayout(output); report["layout"] = layout
        checks["normalLayout"] = layout["normalLayout"] as? Bool == true
        checks["narrowLayout"] = layout["narrowLayout"] as? Bool == true
        checks["settingsReachable"] = layout["settingsReachable"] as? Bool == true
        control.window?.orderOut(nil); store.preferences.scale = 1; applyPreferences(); await wait(0.6)
        if let url = Bundle.main.resourceURL?.appendingPathComponent("web/audio/whale-maid/companion-minimax.mp3"), let data = try? Data(contentsOf: url) {
            do {
                try beginAudio(data, text: "我在呢。今天也陪你一起摸鱼。要是累了，就休息一会儿吧。嗯？你刚刚是不是在叫我？")
                let animation = speechAnimation
                var frames: [[String: Any]] = [], count = 0
                while player?.isPlaying == true && count < 100 {
                    let position = player?.currentTime ?? 0
                    let state = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
                    let expression = state["expression"] as? [String: Any] ?? [:], speech = state["speech"] as? [String: Any] ?? [:]
                    let shape = speech["shape"] as? [String: Any] ?? [:]
                    let name = String(format: "lip-%03d.png", count); await capturePet(output.appendingPathComponent(name))
                    frames.append(["file": name, "time": position, "opening": expression["opening"] ?? 0,
                        "target": shape["open"] ?? 0, "ee": shape["ee"] ?? 0, "ou": shape["ou"] ?? 0,
                        "playhead": speech["playhead"] ?? 0, "meter": lastVolume])
                    count += 1; await wait(0.085)
                }
                let openings = frames.compactMap { $0["opening"] as? Double }
                let wide = frames.compactMap { $0["ee"] as? Double }, round = frames.compactMap { $0["ou"] as? Double }
                let errors = frames.compactMap { row -> Double? in guard let time = row["time"] as? Double, let clock = row["playhead"] as? Double else { return nil }; return abs(clock - time) }
                checks["audioCurveDecoded"] = (animation?.frames.count ?? 0) > 100
                checks["mouthOpensAndCloses"] = (openings.max() ?? 0) > 0.4 && (openings.min() ?? 1) < 0.12
                checks["vowelsVaryWithAudio"] = (wide.max() ?? 0) - (wide.min() ?? 0) > 0.15 && (round.max() ?? 0) - (round.min() ?? 0) > 0.1
                checks["playbackClockAligned"] = !errors.isEmpty && errors.max()! < 0.15
                report["speech"] = ["frames": frames, "curve": animation?.frames ?? [], "analysisSeconds": animation?.analysisSeconds ?? -1,
                    "source": "Existing MiniMax companion-minimax.mp3", "maxClockErrorSeconds": errors.max() ?? -1,
                    "scope": "Actual native playback clock, production WebGL mouth state and snapshots; vowel shapes are spectral estimates, not forced phoneme alignment."]
                stopSpeech()
            } catch { checks["audioCurveDecoded"] = false; diagnostics.append(error.localizedDescription) }
        }
        let wake = VoiceWake(); var utterances: [[String: Any]] = [], partials: [[String: Any]] = [], events: [String] = []
        let started = ProcessInfo.processInfo.systemUptime
        wake.onEvent = { event in
            switch event {
            case .utterance(let text): utterances.append(["text": text, "time": ProcessInfo.processInfo.systemUptime - started])
            case .partial(let text): partials.append(["text": text, "time": ProcessInfo.processInfo.systemUptime - started])
            case .woke: events.append("woke@\(ProcessInfo.processInfo.systemUptime - started)")
            case .failure(let error): events.append(error)
            default: break
            }
        }
        do {
            let fixture = output.deletingLastPathComponent().appendingPathComponent("turn-pause.aiff")
            try await wake.replayForCheck(fixture, phrase: "小鲸小鲸")
            let text = utterances.first?["text"] as? String ?? ""
            checks["thinkingPauseKeepsOneTurn"] = utterances.count == 1 && text.contains("一件事") && text.contains("散步")
            report["turn"] = ["utterances": utterances, "partials": partials, "events": events, "silenceInsideUtteranceSeconds": 1.8,
                "pauseWaitSeconds": 3, "stats": await wake.diagnosticsForCheck(), "scope": "Real on-device Chinese recognition of two spoken clauses separated by 1.8 seconds of silence; no online conversation request."]
        } catch { checks["thinkingPauseKeepsOneTurn"] = false; diagnostics.append(error.localizedDescription) }
        report["checks"] = checks; report["errors"] = diagnostics; report["success"] = checks.values.allSatisfy { $0 } && diagnostics.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("conversation-report.json"))
        }
    }
}
