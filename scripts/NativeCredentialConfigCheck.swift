import Foundation

@main struct NativeCredentialConfigCheck {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let value = "public-fixture-model-key-0123456789", voice = "public-fixture-voice-key-9876543210"
        var checks: [String: Bool] = [:]
        func expectFailure(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let store = PreferencesStore(directory: root, testing: true)
        let file = root.appendingPathComponent("credentials.json"), config = PetCredentialConfig(file: file)
        if CommandLine.arguments[1] == "seed" {
            try store.keychain.write(value, account: "chat"); try store.keychain.write(voice, account: "voice")
            try store.savePreferences()
            checks["modelKeyStoredAsPlaintext"] = try Data(contentsOf: file).range(of: Data(value.utf8)) != nil
            checks["preferencesDoNotSerializeKeys"] = try Data(contentsOf: root.appendingPathComponent("settings.json")).range(of: Data(value.utf8)) == nil
            checks["onlyOwnerCanReadWrite"] = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600
            checks["maskedPreview"] = store.keychain.preview("chat") == TokenPreview.mask(value)
        } else if CommandLine.arguments[1] == "verify" {
            checks["modelKeySurvivesNewProcess"] = try store.keychain.read("chat") == value
            checks["voiceKeySurvivesNewProcess"] = try store.keychain.read("voice") == voice
            try store.keychain.write("", account: "chat")
            var fallbackCalled = false
            checks["removedKeyDoesNotReturnFromLegacy"] = try config.read("chat") { fallbackCalled = true; return value }.isEmpty && !fallbackCalled
            checks["removedPreviewIsEmpty"] = store.keychain.preview("chat") == nil
            checks["removalRetainsVoiceKey"] = try store.keychain.read("voice") == voice
            try store.keychain.write(value, account: "chat")
            let migration = PetCredentialConfig(file: root.appendingPathComponent("migration/credentials.json"))
            checks["legacyValueMigrates"] = try migration.read("chat") { value } == value
            checks["migrationIsIdempotent"] = try migration.read("chat") { throw PetError("Must not consult legacy again") } == value
            let unavailable = PetCredentialConfig(file: root.appendingPathComponent("unavailable/credentials.json"))
            checks["unavailableLegacyHasActionableError"] = expectFailure { _ = try unavailable.read("chat") { throw PetError("locked") } }
            checks["unavailableMigrationDoesNotCreateEmptyFile"] = !FileManager.default.fileExists(atPath: unavailable.file.path)
            try unavailable.write(value, account: "chat")
            checks["resaveBypassesUnavailableLegacy"] = try unavailable.read("chat") { throw PetError("locked") } == value
            let original = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            checks["readonlySaveFails"] = expectFailure { try config.write("replacement", account: "chat") }
            checks["readonlyOriginalAndModeRetained"] = try Data(contentsOf: file) == original && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o400
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Data("{invalid".utf8).write(to: file)
            checks["corruptConfigIsNotOverwritten"] = try expectFailure { try config.write(value, account: "chat") } && Data(contentsOf: file) == Data("{invalid".utf8)
            try original.write(to: file)
            let link = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            checks["symbolicLinkReadRejected"] = expectFailure { _ = try PetCredentialConfig(file: link).value("chat") }
            checks["symbolicLinkWriteRejected"] = expectFailure { try PetCredentialConfig(file: link).write("replacement", account: "chat") }
            checks["symbolicLinkTargetPreserved"] = try Data(contentsOf: file) == original
            checks["oversizedValueRejected"] = expectFailure { try config.write(String(repeating: "x", count: 140_000), account: "chat") }
            checks["failedLargeWriteRetainsKeys"] = try store.keychain.read("chat") == value && store.keychain.read("voice") == voice
        } else if CommandLine.arguments[1] == "probe" {
            var preferences = store.preferences
            preferences.endpoint = CommandLine.arguments[3]; preferences.model = "fixture-model"
            _ = try await CompanionService.probe(preferences: preferences, key: store.keychain.read("chat"))
            checks["localServiceUsesSavedConfigurationKey"] = true
        }
        guard !checks.isEmpty, checks.values.allSatisfy({ $0 }) else { throw PetError("Credential configuration check failed: \(checks.filter { !$0.value }.keys.sorted())") }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "checks": checks], options: [.sortedKeys]), as: UTF8.self))
    }
}
