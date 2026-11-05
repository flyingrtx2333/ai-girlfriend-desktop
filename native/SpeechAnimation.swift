import Foundation
import AudioToolbox
import Accelerate

private final class AudioBytes { let data: Data; init(_ data: Data) { self.data = data } }

// A small audio-derived mouth curve, decoded entirely in RAM. These are
// approximate vowel shapes, not a phoneme recognizer or a text-timed animation.
struct SpeechAnimation {
    let frames: [[Double]] // seconds, opening, wide/ee, rounded/ou
    let analysisSeconds: Double
    init(data: Data, duration: Double) throws {
        let began = ProcessInfo.processInfo.systemUptime, source = AudioBytes(data)
        defer { withExtendedLifetime(source) {} }
        let context = Unmanaged.passUnretained(source).toOpaque()
        var file: AudioFileID?
        let opened = AudioFileOpenWithCallbacks(context, { context, offset, count, destination, actual in
            let bytes = Unmanaged<AudioBytes>.fromOpaque(context).takeUnretainedValue().data
            guard offset >= 0, offset < bytes.count else { actual.pointee = 0; return noErr }
            let size = min(Int(count), bytes.count - Int(offset)); actual.pointee = UInt32(size)
            bytes.withUnsafeBytes { if let pointer = $0.baseAddress { memcpy(destination, pointer.advanced(by: Int(offset)), size) } }
            return noErr
        }, nil, { Int64(Unmanaged<AudioBytes>.fromOpaque($0).takeUnretainedValue().data.count) }, nil, 0, &file)
        guard opened == noErr, let file else { throw PetError("口型音频无法解码。") }
        defer { AudioFileClose(file) }
        var extended: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(file, false, &extended) == noErr, let extended else { throw PetError("口型音频无法读取。") }
        defer { ExtAudioFileDispose(extended) }
        let rate = 16000.0, window = 512, hop = 320
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: format)), &format) == noErr,
              let fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { throw PetError("口型分析无法启动。") }
        defer { vDSP_destroy_fftsetup(fft) }
        var hann = [Float](repeating: 0, count: window), input = hann
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        var real = [Float](repeating: 0, count: window / 2), imaginary = real, power = real
        var chunk = [Float](repeating: 0, count: 4096), pending: [Float] = [], rows: [[Double]] = []
        var read = 0, cursor = 0
        while true {
            var count: UInt32 = 4096
            let status = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(extended, &count, &list)
            }
            guard status == noErr else { throw PetError("口型音频解码失败。") }
            if count == 0 { break }
            pending.append(contentsOf: chunk.prefix(Int(count)))
            while pending.count - cursor >= window {
                var energy: Float = 0
                for i in 0..<window { let sample = pending[cursor + i]; energy += sample * sample; input[i] = sample * hann[i] }
                real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    input.withUnsafeBufferPointer { samples in
                        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: window / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(window / 2)) }
                    }
                    vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(window / 2))
                } }
                func band(_ low: Double, _ high: Double) -> Double {
                    let first = Int(low / rate * Double(window)), last = min(power.count - 1, Int(high / rate * Double(window)))
                    return Double(power[first...last].reduce(0, +))
                }
                rows.append([Double(read + cursor + window / 2) / rate, Double(sqrt(energy / Float(window))),
                             band(180, 650), band(650, 1400), band(1500, 3500)])
                cursor += hop
            }
            pending.removeFirst(cursor); read += cursor; cursor = 0
        }
        let levels = rows.map { $0[1] }.sorted(), reference = max(0.015, levels.isEmpty ? 0.015 : levels[Int(Double(levels.count - 1) * 0.9)])
        let gate = max(0.0015, reference * 0.055), decodedSeconds = Double(read + pending.count) / rate
        func bounded(_ x: Double) -> Double { min(1, max(0, x)) }
        func rounded(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        frames = [[0, 0, 0, 0]] + rows.map { row in
            let total = row[2] + row[3] + row[4] + 0.000001
            let wide = bounded((row[4] / total - 0.18) * 2)
            let round = bounded((row[2] / total - 0.42) * 1.7) * (1 - wide * 0.8)
            let opening = pow(bounded((row[1] - gate) / max(0.001, reference - gate)), 0.7) * 0.82
            return [rounded(row[0] * duration / max(0.001, decodedSeconds)), rounded(opening), rounded(wide), rounded(round)]
        } + [[duration, 0, 0, 0]]
        analysisSeconds = ProcessInfo.processInfo.systemUptime - began
    }
}
