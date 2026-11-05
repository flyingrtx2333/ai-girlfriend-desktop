import Foundation
import AVFoundation

@main struct SherpaWakeCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), model = try SherpaWake(phrase: "小鲸小鲸", directory: directory)
        var rows: [[String: Any]] = []
        for name in ["wake-command", "no-wake", "near-wake"] {
            model.reset(); let url = URL(fileURLWithPath: "evidence/edition24/\(name).aiff")
            let file = try AVAudioFile(forReading: url), format = file.processingFormat
            var hits = 0; let started = ProcessInfo.processInfo.systemUptime
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                try file.read(into: buffer)
                if model.accept(buffer.floatChannelData![0], count: Int(buffer.frameLength), sampleRate: Int(format.sampleRate)) { hits += 1 }
            }
            let silence = [Float](repeating: 0, count: Int(format.sampleRate * 0.8))
            silence.withUnsafeBufferPointer { if model.accept($0.baseAddress!, count: $0.count, sampleRate: Int(format.sampleRate)) { hits += 1 } }
            let duration = Double(file.length) / format.sampleRate, seconds = ProcessInfo.processInfo.systemUptime - started
            rows.append(["fixture": name, "hits": hits, "durationSeconds": duration, "processingSeconds": seconds, "realTimeFactor": seconds / duration])
            guard hits == (name == "wake-command" ? 1 : 0) else { throw PetError("Unexpected keyword hits: \(rows)") }
        }
        let report: [String: Any] = ["success": true, "backend": "sherpa-onnx 2.0.1 CPU, 1 thread, zh-en 3M int8", "rows": rows,
            "scope": "Actual keyword inference on Chinese spoken fixtures. Not microphone or conversation-provider validation."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "evidence/edition24/kws-report.json")); print(String(data: data, encoding: .utf8)!)
    }
}
