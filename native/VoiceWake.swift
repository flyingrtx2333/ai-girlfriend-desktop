import Foundation
@preconcurrency import AVFoundation
import Speech

struct WakePhrase {
    let text: String
    static func key(_ text: String) -> String {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        return latin.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh-CN"))
            .filter { $0.isLetter || $0.isNumber }
    }
    // Preserve the command's original text and positions; pinyin only matches
    // the wake phrase, including recognizer spellings such as 小精 / 小鲸.
    func command(in transcript: String) -> String? {
        let letters = transcript.indices.filter { transcript[$0].isLetter || transcript[$0].isNumber }
        let length = text.filter { $0.isLetter || $0.isNumber }.count
        guard length >= 2, letters.count >= length else { return nil }
        let wanted = Self.key(text)
        for start in 0...(letters.count - length) {
            let end = transcript.index(after: letters[start + length - 1])
            if Self.key(String(transcript[letters[start]..<end])) == wanted {
                return String(transcript[end...].drop { $0.isWhitespace || $0.isPunctuation })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// One native microphone tap. Sherpa handles acoustic wake words; Apple ASR
// only starts after a keyword hit or explicit listen/follow-up. No audio files.
final class VoiceWake: @unchecked Sendable {
    enum Event: Sendable { case state(String), woke, partial(String), utterance(String), failure(String) }
    @MainActor var onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "com.xjs.bluefatfish.voice", qos: .utility)
    @MainActor private var requested = false
    @MainActor private var configuredPhrase = ""
    @MainActor private var permissionTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var engineChange: NSObjectProtocol?
    private var inputWatchdog: DispatchSourceTimer?
    private var micBuffers = 0, captureStarts = 0, captureRestarts = 0, restartAttempts = 0
    private var lastMicAt = 0.0, peakRMS: Float = 0
    private var recognizer: SFSpeechRecognizer?
    private var keywordSpotter: SherpaWake?
    private var keywordRunning = false, keywordStarted = 0.0
    private var asrStarts = 0, keywordHits = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var phrase = WakePhrase(text: "小鲸小鲸")
    private var enabled = false, outputBusy = false, awake = false, conversation = false, sessionHasWake = false
    private var epoch = 0, session = 0, consecutiveErrors = 0
    private var preRoll: [AVAudioPCMBuffer] = []
    private var command = "", lastPartial = ""
    private var noise: Float = 0.0005
    private var loudDuration = 0.0, lastLoud = 0.0, started = 0.0, ending = 0.0, deadline = 0.0, cooldown = 0.0

    @MainActor func configure(enabled: Bool, phrase: String) {
        guard enabled != requested || phrase != configuredPhrase else { return }
        requested = enabled; configuredPhrase = phrase; permissionTask?.cancel()
        queue.async { self.restartAttempts = 0; self.stopCapture(notify: !enabled) }
        guard enabled else { return }
        emit(.state("等待授权"))
        permissionTask = Task {
            let mic = await Self.microphonePermission()
            guard !Task.isCancelled else { return }
            guard mic else { emit(.failure("请允许麦克风权限")); return }
            let speech = await Self.speechPermission()
            guard !Task.isCancelled else { return }
            guard speech else { emit(.failure("请允许语音识别权限")); return }
            queue.async { self.startCapture(phrase: phrase) }
        }
    }
    @MainActor func stop() { requested = false; permissionTask?.cancel(); queue.async { self.stopCapture() } }
    func setOutputBusy(_ busy: Bool, followUp: Bool = false) {
        queue.async {
            guard self.enabled else { return }
            if busy { self.outputBusy = true; self.cancelRecognition(); self.resetKeyword(); self.preRoll.removeAll(); self.emit(.state("回复中")); return }
            let wasBusy = self.outputBusy; self.outputBusy = false
            if wasBusy { self.cooldown = ProcessInfo.processInfo.systemUptime + 0.6 }
            if followUp && self.conversation { self.awake = true; self.deadline = ProcessInfo.processInfo.systemUptime + 12 }
            self.emit(.state(self.awake ? "聆听中" : "等待唤醒"))
        }
    }
    func listenNow() {
        queue.async {
            guard self.enabled else { return }
            self.cancelRecognition(); self.resetKeyword(); self.preRoll.removeAll(); self.outputBusy = false; self.conversation = true; self.awake = true
            self.deadline = ProcessInfo.processInfo.systemUptime + 10; self.emit(.woke)
        }
    }
    func resetConversation() {
        queue.async {
            self.cancelRecognition(); self.resetKeyword(); self.preRoll.removeAll(); self.awake = false; self.conversation = false; self.outputBusy = false
            if self.enabled { self.emit(.state("等待唤醒")) }
        }
    }
    private func emit(_ event: Event) { DispatchQueue.main.async { [weak self] in self?.onEvent?(event) } }
    @MainActor static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
        default: return false
        }
    }
    @MainActor static func speechPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return false }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
    private func prepare(phrase: String) -> Bool {
        stopCapture(notify: false)
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("wake-model") else { emit(.failure("唤醒模型缺失。")); return false }
        do { keywordSpotter = try SherpaWake(phrase: phrase, directory: directory) }
        catch { emit(.failure(error.localizedDescription)); return false }
        asrStarts = 0; keywordHits = 0
        self.phrase = WakePhrase(text: phrase); enabled = true
        return true
    }
    private func startCapture(phrase: String) {
        guard prepare(phrase: phrase) else { return }
        let engine = AVAudioEngine(), captureEpoch = epoch
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stopCapture(); emit(.failure("麦克风不可用")); return }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in source.indices { if let src = source[i].mData, let dst = target[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)); target[i].mDataByteSize = source[i].mDataByteSize } }
            self.queue.async {
                if self.enabled && self.epoch == captureEpoch {
                    self.micBuffers += 1; self.lastMicAt = ProcessInfo.processInfo.systemUptime; self.restartAttempts = 0
                    self.consume(copy)
                }
            }
        }
        do {
            engine.prepare(); try engine.start(); self.engine = engine
            captureStarts += 1; lastMicAt = ProcessInfo.processInfo.systemUptime
            engineChange = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
                // The notification arrives on Core Audio's internal queue.
                // Rebuild asynchronously after the route has settled.
                self?.queue.asyncAfter(deadline: .now() + 0.35) { [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine, self.enabled else { return }
                    self.recoverCapture()
                }
            }
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(400))
            watchdog.setEventHandler { [weak self] in
                guard let self, self.enabled, let engine = self.engine else { return }
                if !engine.isRunning || ProcessInfo.processInfo.systemUptime - self.lastMicAt > 4 { self.recoverCapture() }
            }
            inputWatchdog = watchdog; watchdog.resume(); emit(.state("等待唤醒"))
        }
        catch { engine.inputNode.removeTap(onBus: 0); stopCapture(); emit(.failure("麦克风启动失败")) }
    }
    private func recoverCapture() {
        guard enabled else { return }
        guard restartAttempts < 3 else { stopCapture(); emit(.failure("麦克风无输入，请检查输入设备后重新开启。")); return }
        restartAttempts += 1; captureRestarts += 1
        let busy = outputBusy, text = phrase.text
        emit(.state("恢复麦克风")); startCapture(phrase: text)
        if enabled && busy { outputBusy = true; emit(.state("回复中")) }
    }
    private func stopCapture(notify: Bool = true) {
        epoch += 1; enabled = false; cancelRecognition()
        if let engineChange { NotificationCenter.default.removeObserver(engineChange); self.engineChange = nil }
        inputWatchdog?.cancel(); inputWatchdog = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; recognizer = nil
        keywordSpotter = nil; keywordRunning = false; keywordStarted = 0
        preRoll.removeAll(); awake = false; conversation = false; outputBusy = false; loudDuration = 0; noise = 0.0005
        if notify { emit(.state("未开启")) }
    }
    private func consume(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !outputBusy, now >= cooldown, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength); var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(max(1, count))), duration = Double(count) / buffer.format.sampleRate
        peakRMS = max(peakRMS, rms)
        // Skip near-silence only; the acoustic keyword model decides the wake.
        let loud = rms > max(0.002, min(0.006, noise * 2.8))
        if !awake { noise = noise * 0.995 + min(rms, 0.015) * 0.005 }
        loudDuration = loud ? min(1, loudDuration + duration) : max(0, loudDuration - duration * 2)
        if loud { lastLoud = now }
        if awake && now > deadline && command.isEmpty { awake = false; conversation = false; cancelRecognition(); resetKeyword(); emit(.state("等待唤醒")) }
        if !awake {
            // A cheap sound gate suspends keyword inference during quiet gaps.
            // Two seconds of RAM pre-roll retain the wake phrase and a command
            // spoken immediately after it. Reset streams bound feature history.
            appendPreRoll(buffer, seconds: 2)
            var hit = false
            if !keywordRunning && loudDuration > 0.04 {
                resetKeyword(); keywordRunning = true; keywordStarted = now
                for previous in preRoll { if acceptKeyword(previous) { hit = true; break } }
            } else if keywordRunning { hit = acceptKeyword(buffer) }
            if hit {
                keywordHits += 1; awake = true; conversation = true; deadline = now + 10
                emit(.woke); resetKeyword(); beginRecognition(now: now, includesWake: true)
                preRoll.forEach { request?.append($0) }; preRoll.removeAll()
            } else if keywordRunning && (now - lastLoud > 0.85 || now - keywordStarted > 20) { resetKeyword() }
            return
        }
        if request == nil {
            appendPreRoll(buffer, seconds: 0.4)
            if loudDuration > 0.06 { beginRecognition(now: now); preRoll.forEach { request?.append($0) }; preRoll.removeAll() }
            return
        }
        if ending == 0 {
            request?.append(buffer)
            if now - lastLoud > 0.85 || now - started > 15 { ending = now; request?.endAudio() }
        } else if now - ending > 1.2 { finishSession() }
    }
    private func appendPreRoll(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        preRoll.append(buffer)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let limit = max(2, Int(seconds / duration)); if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
    }
    private func acceptKeyword(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        return keywordSpotter?.accept(samples, count: Int(buffer.frameLength), sampleRate: Int(buffer.format.sampleRate)) == true
    }
    private func resetKeyword() { keywordRunning = false; keywordStarted = 0; keywordSpotter?.reset() }
    private func beginRecognition(now: Double, includesWake: Bool = false) {
        guard awake else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            stopCapture(); emit(.failure("本机中文离线识别不可用")); return
        }
        self.recognizer = recognizer; asrStarts += 1
        session += 1; let id = session
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.contextualStrings = [phrase.text]; request.taskHint = .dictation
        self.request = request; started = now; ending = 0; command = ""; lastPartial = ""; sessionHasWake = includesWake
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.enabled, self.session == id, !self.outputBusy else { return }
                if let result { self.receive(result.bestTranscription.formattedString, final: result.isFinal) }
                if error != nil && self.session == id {
                    if (error as NSError?)?.code != 1110 { self.consecutiveErrors += 1 }
                    self.finishSession()
                    if self.consecutiveErrors >= 4 { self.stopCapture(); self.emit(.failure("本机语音识别暂不可用")) }
                }
            }
        }
    }
    private func receive(_ text: String, final: Bool) {
        guard awake else { return }
        if !text.isEmpty { consecutiveErrors = 0 }
        if sessionHasWake {
            if let suffix = phrase.command(in: text) { command = suffix }
            else if WakePhrase.key(phrase.text).hasPrefix(WakePhrase.key(text)) { command = "" }
            else { command = text }
        } else { command = text }
        if !command.isEmpty && command != lastPartial { lastPartial = command; emit(.partial(command)) }
        if final { finishSession() }
    }
    private func finishSession() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRecognition(); preRoll.removeAll(); loudDuration = 0
        guard awake, !text.isEmpty else { return }
        if ["停止聆听", "别听了", "休息吧", "取消"].contains(text.trimmingCharacters(in: .punctuationCharacters)) {
            awake = false; conversation = false; emit(.state("等待唤醒")); return
        }
        awake = false; outputBusy = true; emit(.state("回复中")); emit(.utterance(text))
    }
    private func cancelRecognition() {
        session += 1; request?.endAudio(); task?.cancel(); request = nil; task = nil; recognizer = nil
        command = ""; lastPartial = ""; ending = 0
    }
    @MainActor func diagnosticsForCheck() async -> [String: Int] {
        await withCheckedContinuation { c in queue.async {
            c.resume(returning: ["keywordHits": self.keywordHits, "asrStarts": self.asrStarts,
                "micBuffers": self.micBuffers, "captureStarts": self.captureStarts, "captureRestarts": self.captureRestarts,
                "engineRunning": self.engine?.isRunning == true ? 1 : 0, "enabled": self.enabled ? 1 : 0,
                "lastBufferAgeMs": self.lastMicAt == 0 ? -1 : Int((ProcessInfo.processInfo.systemUptime - self.lastMicAt) * 1000),
                "peakInputDb": Int(20 * log10(max(0.000001, self.peakRMS)))])
        } }
    }
    @MainActor func interruptInputForCheck(notify: Bool) async {
        await withCheckedContinuation { c in queue.async {
            if let engine = self.engine {
                engine.stop()
                if notify { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
            }
            c.resume()
        } }
    }
    // Feed a real spoken fixture through the same KWS, local recognizer and turn
    // assembly as the microphone. Only the native --voice-check uses this path.
    @MainActor func replayForCheck(_ url: URL, phrase: String) async throws {
        guard await Self.speechPermission() else { throw PetError("语音识别权限未开启") }
        let prepared = await withCheckedContinuation { c in queue.async { c.resume(returning: self.prepare(phrase: phrase)) } }
        guard prepared else { throw PetError("本机中文离线识别不可用") }
        let file = try AVAudioFile(forReading: url), format = file.processingFormat
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { break }
            try file.read(into: buffer); queue.async { self.consume(buffer) }
            try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / format.sampleRate * 1_000_000_000))
        }
        for _ in 0..<Int(format.sampleRate * 2.5 / 1024) {
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!; silence.frameLength = 1024
            for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            queue.async { self.consume(silence) }
            try await Task.sleep(nanoseconds: UInt64(1024 / format.sampleRate * 1_000_000_000))
        }
        try await Task.sleep(nanoseconds: 1_000_000_000); stop()
    }
}
