import AppKit

// A public, deterministic scene for vision checks; never a private desktop image.
private final class ScreenCheckScene: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.78, green: 0.91, blue: 0.98, alpha: 1).setFill(); bounds.fill()
        NSColor.white.setFill()
        for x in [90, 310, 560] { NSBezierPath(ovalIn: NSRect(x: x, y: 292, width: 100, height: 27)).fill() }
        NSColor(calibratedRed: 0.38, green: 0.66, blue: 0.47, alpha: 1).setFill()
        for x in stride(from: -100, to: 850, by: 200) {
            let mountain = NSBezierPath(); mountain.move(to: NSPoint(x: x, y: 100)); mountain.line(to: NSPoint(x: x + 160, y: 290)); mountain.line(to: NSPoint(x: x + 320, y: 100)); mountain.close(); mountain.fill()
        }
        NSColor(calibratedRed: 0.31, green: 0.70, blue: 0.84, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 800, height: 125).fill()
        NSColor(calibratedWhite: 0.48, alpha: 1).setFill(); NSRect(x: 0, y: 116, width: 800, height: 17).fill()
        for x in [110, 340, 580] { NSRect(x: x, y: 0, width: 35, height: 116).fill() }
        for x in [160, 300, 440] {
            NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 143, width: 132, height: 64), xRadius: 10, yRadius: 10).fill()
            NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.34, alpha: 1).setFill()
            for dx in [14, 51, 88] { NSBezierPath(roundedRect: NSRect(x: x + dx, y: 172, width: 27, height: 24), xRadius: 3, yRadius: 3).fill() }
            NSColor.darkGray.setFill()
            for dx in [25, 91] { NSBezierPath(ovalIn: NSRect(x: x + dx, y: 130, width: 26, height: 26)).fill() }
        }
    }
}

@MainActor extension AppDelegate {
    func runScreenCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        let p = store.preferences
        checks["automaticObservationDefaultsOff"] = !p.screenObservationEnabled && !screenCompanion.isAvailable(manual: false)
        store.preferences.screenObservationEnabled = true
        store.preferences.screenQuietUntil = Date().addingTimeInterval(1800)
        checks["quietBlocksAutomaticObservation"] = !screenCompanion.isAvailable(manual: false)
        store.preferences.screenQuietUntil = nil; store.preferences.performance = "paused"
        checks["pausedBlocksManualObservation"] = !screenCompanion.isAvailable(manual: true)
        store.preferences.performance = "auto"; wakeStatus = "聆听中"
        checks["listeningBlocksManualObservation"] = !screenCompanion.isAvailable(manual: true)
        wakeStatus = "未开启"; store.preferences = p
        var poses: [String: [Double]] = [:]
        for phase in ["observing", "thinking", "commenting"] {
            emit("screenState", ["phase": phase, "direction": -0.65]); await wait(1.65)
            let values = await evaluate("window.whaleDiagnostics()") as? [String: Any] ?? [:]
            checks[phase + "ReachesRenderer"] = (values["screen"] as? [String: Any])?["phase"] as? String == phase
            checks[phase + "KeepsRenderBudget"] = values["drawCalls"] as? Int == 2 && (values["triangles"] as? Int ?? 999999) < 60_000
            poses[phase] = (values["expression"] as? [String: Any])?["head"] as? [Double] ?? []
            await capturePet(output.appendingPathComponent(phase + ".png"))
        }
        checks["observationAndThinkingHaveDistinctPoses"] = zip(poses["observing"] ?? [], poses["thinking"] ?? []).contains { abs($0 - $1) > 0.04 }
        emit("screenState", ["phase": "idle"])
        let fixture = NSWindow(contentRect: NSRect(x: 80, y: 180, width: 800, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        fixture.title = "小鲸 · 视觉验证画面"; fixture.isReleasedWhenClosed = false
        let scene = ScreenCheckScene(frame: NSRect(x: 0, y: 0, width: 800, height: 360)); fixture.contentView = scene
        fixture.orderFrontRegardless(); await wait(0.2)
        do {
            guard let bitmap = scene.bitmapImageRepForCachingDisplay(in: scene.bounds) else { throw PetError("固定画面未绘制") }
            scene.cacheDisplay(in: scene.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("public-scene.png")) }
            guard let image = bitmap.cgImage else { throw PetError("固定画面无法读取") }
            var frame = try ScreenFrame.encode(image)
            checks["unchangedFrameDetectedLocally"] = frame.difference(from: frame.thumbnail) == 0
            checks["smallInMemoryJPEG"] = frame.jpeg.count < 300_000 && max(frame.width, frame.height) <= 1280
            if CommandLine.arguments.contains("--capture-fixture") {
                frame = try await ScreenFrame.capture(windowID: CGWindowID(fixture.windowNumber))
                checks["realScreenCaptureKitFrame"] = frame.width >= 750 && frame.height >= 350 && max(frame.width, frame.height) <= 1280
                report["capture"] = ["method": "ScreenCaptureKit single-frame screenshot of the controlled fixture window", "width": frame.width, "height": frame.height, "jpegBytes": frame.jpeg.count]
            }
            if CommandLine.arguments.contains("--live-vision") {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                let production = PreferencesStore(directory: directory)
                let preferences = production.preferences
                emit("screenState", ["phase": "thinking"])
                let reply = try await CompanionService.screenComment(jpeg: frame.jpeg, preferences: preferences, key: production.keychain.read("chat"))
                report["vision"] = ["model": preferences.model, "reply": reply ?? "[安静]", "independentSceneFacts": "Orange three-car train on a bridge over a blue river, green mountains and white clouds. The model prompt contains none of these facts."]
                checks["liveVisionReturnsComment"] = reply != nil
                if let reply, preferences.voiceEnabled {
                    let audio = try await CompanionService.speech(text: reply, preferences: preferences, key: production.keychain.read("voice"))
                    emit("screenState", ["phase": "commenting"])
                    try beginAudio(audio, text: reply, followUp: false); await wait(0.7)
                    checks["realMiniMaxPlayback"] = player?.isPlaying == true && speechAnimation?.frames.isEmpty == false
                    checks["spontaneousCommentDoesNotOpenFollowUpMic"] = !speechFollowUp
                    report["voice"] = ["model": preferences.voiceModel, "audioSeconds": player?.duration ?? 0, "curveFrames": speechAnimation?.frames.count ?? 0]
                    await capturePet(output.appendingPathComponent("live-comment.png")); stopSpeech()
                }
            }
        } catch { checks["scenePipeline"] = false; report["error"] = error.localizedDescription }
        fixture.orderOut(nil); emit("screenState", ["phase": "idle"])
        report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["poses"] = poses
        report["scope"] = "Independent profile and a fixed public scene; no private screen content, transcript or credentials in this report. Online vision/TTS and real ScreenCaptureKit capture run only with their explicit flags."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("screen-report.json")) }
    }
}
