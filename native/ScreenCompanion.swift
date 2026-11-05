import AppKit
import ScreenCaptureKit
import os

struct ScreenFrame {
    let jpeg: Data
    let thumbnail: [UInt8]
    let width: Int, height: Int

    static func capture(processID: pid_t? = nil, windowID: CGWindowID? = nil) async throws -> ScreenFrame {
        guard CGPreflightScreenCaptureAccess() else { throw PetError("需要屏幕录制权限") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == processID }
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let candidates = windowID.map { [$0] } ?? order
        guard let window = candidates.compactMap({ id in content.windows.first { $0.windowID == id && $0.frame.width > 160 && $0.frame.height > 120 } }).first else {
            throw PetError("没有可观察的应用窗口")
        }
        let ratio = min(1, 1280 / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * ratio)); configuration.height = max(1, Int(window.frame.height * ratio))
        configuration.showsCursor = false; configuration.capturesAudio = false; configuration.scalesToFit = true
        if #available(macOS 14.0, *) { configuration.ignoreShadowsSingleWindow = true }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try Task.checkCancellation()
        return try encode(image)
    }
    static func encode(_ original: CGImage) throws -> ScreenFrame {
        var image = original
        if max(original.width, original.height) > 1280 {
            let ratio = 1280 / Double(max(original.width, original.height)), width = Int(Double(original.width) * ratio), height = Int(Double(original.height) * ratio)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError("画面无法缩小") }
            context.interpolationQuality = .medium; context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw PetError("画面无法缩小") }; image = scaled
        }
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.68]), jpeg.count <= 900_000 else {
            throw PetError("画面过大，请缩小窗口后重试")
        }
        var pixels = [UInt8](repeating: 0, count: 32 * 18 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low; context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18)); return true
        }
        guard drawn else { throw PetError("画面无法读取") }
        return ScreenFrame(jpeg: jpeg, thumbnail: pixels, width: image.width, height: image.height)
    }
    func difference(from previous: [UInt8]) -> Double {
        guard previous.count == thumbnail.count else { return 1 }
        return Double(zip(thumbnail, previous).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(thumbnail.count * 255)
    }
}

@MainActor final class ScreenCompanion {
    weak var host: AppDelegate?
    var onChange: ((String) -> Void)?
    private(set) var status = "未开启", phase = "idle"
    private(set) var captures = 0, requests = 0, comments = 0, similarSkipped = 0
    private var timer: Timer?, task: Task<Void, Never>?
    private var generation = 0, failures = 0
    private var observingManually = false
    private let logger = Logger(subsystem: "com.xjs.bluefatfish", category: "ScreenCompanion")
    private var lastInteraction = Date(), nextObservation = Date.distantFuture
    private var lastThumbnail: [UInt8] = [], lastProcess: pid_t?
    private var recentComments: [String] = []
    private var externalApplication: NSRunningApplication?
    init(host: AppDelegate) { self.host = host; rememberApplication() }

    func rememberApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { externalApplication = app }
    }
    func applicationChanged() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let own = pid == ProcessInfo.processInfo.processIdentifier
        if (phase == "observing" || phase == "thinking") && ((!own && pid != externalApplication?.processIdentifier) || (own && !observingManually)) { interaction() }
        rememberApplication()
    }
    func suspend() { cancel(); timer?.invalidate(); timer = nil }
    func configure() {
        cancel(); timer?.invalidate(); timer = nil
        guard let host, host.checkDirectory == nil, host.store.preferences.screenObservationEnabled else { setStatus("未开启"); return }
        guard host.store.preferences.visionSupported == true else { setStatus("请配置支持视觉的模型"); return }
        guard CGPreflightScreenCaptureAccess() else { setStatus("需要屏幕录制权限"); return }
        nextObservation = Date().addingTimeInterval(interval)
        setStatus(isQuiet ? "免打扰中" : "等待观察")
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        timer.tolerance = 5; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private var isQuiet: Bool { (host?.store.preferences.screenQuietUntil ?? .distantPast) > Date() }
    private var interval: TimeInterval { min(900, max(60, host?.store.preferences.screenObservationInterval ?? 300)) }
    func isAvailable(manual: Bool) -> Bool {
        guard let host, host.ready, host.renderVisible, !host.sleeping, !host.closing,
              host.store.preferences.performance != "paused", host.chatTask == nil, host.speechTask == nil,
              host.player?.isPlaying != true, host.dragOrigin == nil, host.pendingPress == nil, host.wakeStatus != "聆听中" else { return false }
        return manual || (!isQuiet && host.store.preferences.screenObservationEnabled
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier && Date().timeIntervalSince(lastInteraction) >= 20)
    }
    func poll() {
        guard task == nil, Date() >= nextObservation, isAvailable(manual: false) else { return }
        observe(manual: false)
    }
    func interaction() { lastInteraction = Date(); cancel() }
    func cancel() {
        generation += 1; task?.cancel(); task = nil
        let wasCommenting = phase == "commenting", wasLooking = phase == "observing" || phase == "thinking"
        setPhase("idle")
        if wasLooking || wasCommenting { setStatus(host?.store.preferences.screenObservationEnabled == true ? (isQuiet ? "免打扰中" : "等待观察") : "未开启") }
        if wasLooking { host?.bubble?.orderOut(nil) }
        if wasCommenting { host?.stopSpeech() }
    }
    func speechEnded() { if phase == "commenting" { setPhase("idle"); lastInteraction = Date() } }
    private func setStatus(_ value: String) { status = value; onChange?(value) }
    private func setPhase(_ value: String) {
        guard phase != value else { return }
        phase = value
        logger.notice("phase=\(value, privacy: .public)")
        let direction = (host?.pet?.frame.midX ?? 0) < (host?.pet?.screen?.frame.midX ?? 0) ? 0.65 : -0.65
        host?.emit("screenState", ["phase": value, "direction": direction])
    }
    func requestPermission() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        configure()
    }
    func toggleQuiet() {
        guard let host else { return }
        host.store.preferences.screenQuietUntil = isQuiet ? nil : Date().addingTimeInterval(1800)
        try? host.store.savePreferences(); configure()
    }
    func observe(manual: Bool = true) {
        guard task == nil, isAvailable(manual: manual), let host else { if manual { setStatus("等这轮互动结束再看") }; return }
        let preferences = host.store.preferences
        guard preferences.visionSupported == true else { setStatus("请配置支持视觉的模型"); return }
        guard CGPreflightScreenCaptureAccess() else { setStatus("需要屏幕录制权限"); return }
        rememberApplication()
        guard let application = externalApplication, !application.isTerminated else { setStatus("请先切换到要看的应用"); return }
        let pid = application.processIdentifier
        observingManually = manual
        nextObservation = Date().addingTimeInterval(interval)
        generation += 1; let token = generation
        setPhase("observing"); setStatus("看看屏幕…"); host.showBubble("看看屏幕…", duration: 4)
        task = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer {
                if token == self.generation {
                    self.task = nil
                    if self.phase == "observing" || self.phase == "thinking" {
                        host.bubble?.orderOut(nil)
                        if ["看看屏幕…", "想一想…"].contains(self.status) { self.setStatus("等待观察") }
                    }
                    if self.phase != "commenting" || (host.speechTask == nil && host.player?.isPlaying != true) { self.setPhase("idle") }
                }
            }
            do {
                try await Task.sleep(nanoseconds: 1_400_000_000); try Task.checkCancellation()
                guard self.isAvailable(manual: manual) else { return }
                let frame = try await ScreenFrame.capture(processID: pid); self.captures += 1
                self.logger.notice("capture manual=\(manual) width=\(frame.width) height=\(frame.height) bytes=\(frame.jpeg.count)")
                try Task.checkCancellation()
                guard token == self.generation, self.isAvailable(manual: manual) else { return }
                if !manual && pid == self.lastProcess && frame.difference(from: self.lastThumbnail) < 0.025 {
                    self.similarSkipped += 1; self.setStatus("画面相似，稍后再看"); host.bubble?.orderOut(nil); return
                }
                self.setPhase("thinking"); self.setStatus("想一想…"); host.showBubble("想一想…", duration: 35)
                let key = try host.store.keychain.read("chat")
                self.requests += 1
                let reply = try await CompanionService.screenComment(jpeg: frame.jpeg, preferences: preferences, key: key, recent: self.recentComments)
                try await Task.sleep(nanoseconds: 650_000_000); try Task.checkCancellation()
                guard token == self.generation, self.isAvailable(manual: manual) else { return }
                self.lastThumbnail = frame.thumbnail; self.lastProcess = pid; self.failures = 0
                guard let reply, !self.recentComments.contains(reply) else { self.setStatus("看过啦，继续陪你"); host.bubble?.orderOut(nil); return }
                self.comments += 1; self.recentComments = Array((self.recentComments + [reply]).suffix(3))
                self.logger.notice("comment-ready voice=\(preferences.voiceEnabled)")
                host.undoMessages = nil; host.store.messages.append(ChatMessage(role: "assistant", content: reply))
                try? host.store.saveHistory(); host.control.scheduleRender(); host.showBubble(reply)
                if preferences.voiceEnabled { host.synthesize(reply, preferences: preferences, followUp: false) }
                self.setPhase("commenting"); self.setStatus("刚刚看过")
                if !preferences.voiceEnabled { try await Task.sleep(nanoseconds: 3_000_000_000) }
            } catch {
                guard !Task.isCancelled, token == self.generation else { return }
                self.failures += 1
                self.nextObservation = Date().addingTimeInterval(min(1800, self.interval * pow(2, Double(min(3, self.failures)))))
                self.setStatus(error.localizedDescription); host.bubble?.orderOut(nil)
                if manual { host.showBubble(error.localizedDescription) }
            }
        }
    }
}
