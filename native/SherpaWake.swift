import Foundation

// Owned by VoiceWake's serial queue. Only the tiny keyword model runs while
// waiting; Apple transcription is created after an acoustic keyword hit.
final class SherpaWake {
    private let spotter: OpaquePointer
    private var stream: OpaquePointer
    let keyword: String

    static func tokenLine(_ phrase: String, directory: URL) throws -> String {
        let text = phrase.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard (2...12).contains(text.count), text.unicodeScalars.allSatisfy({ (0x4e00...0x9fff).contains($0.value) }),
              let latin = text.applyingTransform(.mandarinToLatin, reverse: false) else {
            throw PetError("唤醒词请用 2–12 个汉字。")
        }
        let vocabulary = Set(try String(contentsOf: directory.appendingPathComponent("tokens.txt"), encoding: .utf8)
            .split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]
        var phones: [String] = []
        for part in latin.lowercased().precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }) {
            let syllable = String(part)
            if let initial = initials.first(where: { syllable.hasPrefix($0) }),
               vocabulary.contains(initial), vocabulary.contains(String(syllable.dropFirst(initial.count))) {
                phones += [initial, String(syllable.dropFirst(initial.count))]
            } else if vocabulary.contains(syllable) { phones.append(syllable) }
            else { throw PetError("唤醒词的读音暂不支持，请换一个。") }
        }
        guard !phones.isEmpty else { throw PetError("唤醒词不可为空。") }
        return phones.joined(separator: " ") + " @" + text + "\n"
    }

    init(phrase: String, directory: URL) throws {
        keyword = phrase.filter { !$0.isWhitespace && !$0.isPunctuation }
        let line = try Self.tokenLine(phrase, directory: directory)
        let names = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
        let paths = names.map { directory.appendingPathComponent($0).path }
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { throw PetError("唤醒模型缺失，请重新安装应用。") }
        let strings = (paths + ["cpu", line]).map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.num_threads = 1; config.model_config.provider = UnsafePointer(strings[4])
        config.max_active_paths = 4; config.num_trailing_blanks = 1
        config.keywords_score = 1; config.keywords_threshold = 0.25
        config.keywords_buf = UnsafePointer(strings[5]); config.keywords_buf_size = Int32(line.utf8.count)
        guard let model = SherpaOnnxCreateKeywordSpotter(&config) else { throw PetError("唤醒模型加载失败。") }
        guard let stream = SherpaOnnxCreateKeywordStream(model) else {
            SherpaOnnxDestroyKeywordSpotter(model); throw PetError("唤醒检测启动失败。")
        }
        spotter = model; self.stream = stream
    }
    deinit { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyKeywordSpotter(spotter) }

    func reset() {
        // Recreate the feature stream as well, bounding retained audio history.
        guard let next = SherpaOnnxCreateKeywordStream(spotter) else { return }
        SherpaOnnxDestroyOnlineStream(stream); stream = next
    }
    func accept(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> Bool {
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(count))
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let hit = result.pointee.keyword.map { String(cString: $0) == keyword } ?? false
            SherpaOnnxDestroyKeywordResult(result)
            if hit { reset(); return true }
        }
        return false
    }
}
