import AppKit
import Security

enum AgentAppVersion {
    static func details(bundle: Bundle = .main) -> [(String, String)] {
        let info = bundle.infoDictionary ?? [:]
        let revision = info["BlueFatFishSourceCommit"] as? String
        let clean = info["BlueFatFishSourceDirty"] as? Bool != true
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rawDate = info["BlueFatFishBuildDate"] as? String ?? ""
        let date = iso.date(from: rawDate) ?? ISO8601DateFormatter().date(from: rawDate)
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        return [("版本", info["CFBundleShortVersionString"] as? String ?? "未记录"),
                ("源码提交", revision.map { String($0.prefix(7)) + (clean ? "" : "（含未提交改动）") } ?? "未记录"),
                ("构建时间", date.map(formatter.string) ?? "未记录"),
                ("签名方式", signingKind(bundle.bundleURL))]
    }
    private static func signingKind(_ application: URL) -> String {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let flags = values[kSecCodeInfoFlags as String] as? NSNumber else { return "未签名或无法读取" }
        // CS_ADHOC from sys/codesign.h is not exported by the Swift Security overlay.
        return flags.uint32Value & 0x2 != 0 ? "本地签名" : "证书签名"
    }
}
