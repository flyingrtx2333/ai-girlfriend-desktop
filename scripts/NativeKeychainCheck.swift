import Foundation
import Security

@main struct NativeKeychainCheck {
    static func main() throws {
        #if UPDATED
        let revision = "updated"
        #else
        let revision = "original"
        #endif
        let mode = CommandLine.arguments[1], service = CommandLine.arguments[2]
        let value = "public-fixture-0123456789-abcdefghijklmnopqrstuvwxyz"
        let store = PetKeychain(service: service)
        var interactive = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&interactive) == errSecSuccess, !interactive.boolValue else { throw PetError("Interaction guard failed") }
        var checks: [String: Bool] = ["interactionDisabled": true]
        switch mode {
        case "legacy-write":
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "chat", kSecValueData as String: Data(value.utf8)]
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PetError("Fixture creation failed") }
        case "write":
            try store.write(value, account: "chat")
            checks["maskedMetadata"] = store.preview("chat") == TokenPreview.mask(value)
        case "read":
            checks["crossBuildRead"] = try store.read("chat") == value
            checks["maskedMetadata"] = store.preview("chat") == TokenPreview.mask(value)
        case "read-legacy":
            checks["oldSecretRetained"] = try store.read("chat") == value
        case "legacy":
            let legacy = CommandLine.arguments[3]
            let migrated = PetKeychain(service: service, legacyService: legacy)
            checks["legacyPreviewWithoutSecret"] = migrated.preview("chat") == "已保存"
            let start = Date()
            do { checks["legacyAccessHandled"] = try migrated.read("chat") == value }
            catch { checks["legacyAccessHandled"] = error.localizedDescription == "旧 Token 需重新粘贴保存一次。" }
            checks["legacyReadReturnsWithoutDialog"] = Date().timeIntervalSince(start) < 3
            checks["oldItemRetained"] = PetKeychain(service: legacy).contains("chat")
            try migrated.write(value, account: "chat")
            checks["resaveUnderStableIdentity"] = try migrated.read("chat") == value
        case "cleanup": try store.write("", account: "chat")
        default: throw PetError("Unknown fixture mode")
        }
        guard checks.values.allSatisfy({ $0 }) else { throw PetError("Keychain checks failed: \(checks)") }
        let report: [String: Any] = ["revision": revision, "mode": mode, "checks": checks]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
