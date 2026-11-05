import Foundation
import Security

struct PetPreferences: Codable {
    var endpoint = "https://api.deepseek.com"
    var model = "deepseek-flash"
    var visionMode = "auto"
    var reasoningEffort = "auto"
    var contextTokens = 8192
    var replyTokens = 512
    var modelInfo: ModelInfo?
    var persona = "你叫小鲸，是一位温柔、俏皮的桌面伙伴。用自然、简短的中文聊天，通常回复一到三句话。认真回应用户的实际内容，少用套话；不编造自己执行过的操作。"
    var voiceEnabled = false
    var voiceEndpoint = "https://api.minimax.cn/v1/t2a_v2"
    var voiceModel = "speech-02-hd"
    var voiceID = "female-shaonv"
    var wakeEnabled = false
    var wakePhrase = "小鲸小鲸"
    var voicePauseSeconds = 3.0
    var alwaysOnTop = true
    var performance = "auto"
    var scale = 1.0
    var positionX: Double?
    var positionY: Double?
}

struct ChatMessage: Codable {
    var id = UUID().uuidString
    var role: String
    var content: String
}

struct PetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct PetKeychain {
    let service: String
    let legacyService: String?
    init(service: String, legacyService: String? = nil) {
        self.service = service; self.legacyService = legacyService
        // The file-based macOS keychain needs this process-local guard; it can
        // otherwise open SecurityAgent before returning an ACL/locked error.
        SecKeychainSetUserInteractionAllowed(false)
    }
    private func query(_ account: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service, kSecAttrAccount as String: account]
    }
    private func attributes(_ account: String, service: String? = nil) -> [String: Any]? {
        var q = query(account, service: service); q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
    func contains(_ account: String) -> Bool { preview(account) != nil }
    // Only metadata, never password bytes, is read while refreshing the form.
    func preview(_ account: String) -> String? {
        if let item = attributes(account) {
            if let data = item[kSecAttrGeneric as String] as? Data, let text = String(data: data, encoding: .utf8) { return text }
            return "已保存"
        }
        if let legacyService, attributes(account, service: legacyService) != nil { return "已保存" }
        return nil
    }
    func read(_ account: String) throws -> String {
        if let value = try secret(account) { return value }
        if let legacyService {
            do {
                if let value = try secret(account, service: legacyService) {
                    // Copy only when macOS already permits access. Never alter
                    // the old item's ACL or delete it during migration.
                    try? write(value, account: account); return value
                }
            } catch { throw PetError("旧 Token 需重新粘贴保存一次。") }
        }
        return ""
    }
    private func secret(_ account: String, service: String? = nil) throws -> String? {
        var q = query(account, service: service); q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PetError("Token 暂不可读，请解锁后重试或重新保存。")
        }
        return value
    }
    func write(_ value: String, account: String) throws {
        let q = query(account)
        let status: OSStatus
        if value.isEmpty {
            if let legacyService {
                let legacy = SecItemDelete(query(account, service: legacyService) as CFDictionary)
                guard [errSecSuccess, errSecItemNotFound].contains(legacy) else { throw PetError("旧 Token 未移除，请在钥匙串访问中处理。") }
            }
            let removed = SecItemDelete(q as CFDictionary)
            status = removed == errSecItemNotFound ? errSecSuccess : removed
        } else {
            let update = [kSecValueData as String: Data(value.utf8), kSecAttrGeneric as String: Data(TokenPreview.mask(value).utf8)]
            let changed = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            if changed == errSecItemNotFound {
                var item = q; item[kSecValueData as String] = Data(value.utf8)
                item[kSecAttrGeneric as String] = Data(TokenPreview.mask(value).utf8)
                item[kSecAttrLabel as String] = "蓝色大肥鱼 · \(account == "chat" ? "对话" : "语音")"
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = changed }
        }
        guard status == errSecSuccess else { throw PetError("Token 未保存，请解锁后重试。") }
    }
}

final class PreferencesStore {
    let directory: URL
    let keychain: PetKeychain
    var preferences = PetPreferences()
    var messages: [ChatMessage] = []
    init(directory: URL, testing: Bool = false) {
        self.directory = directory
        keychain = PetKeychain(service: testing ? "com.xjs.bluefatfish.check.credentials" : "com.xjs.bluefatfish.credentials",
                               legacyService: testing ? nil : "com.xjs.bluefatfish")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Merge defaults so a later version can add fields without losing settings.
        if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let baseline = try? JSONEncoder().encode(preferences),
           var merged = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any] {
            merged.merge(saved) { _, new in new }
            if let json = try? JSONSerialization.data(withJSONObject: merged),
               let decoded = try? JSONDecoder().decode(PetPreferences.self, from: json) { preferences = decoded }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("history.json")),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = Array(decoded.filter { ["user", "assistant"].contains($0.role) }.suffix(80))
        }
    }
    private func save<T: Encodable>(_ value: T, file: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(file)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func savePreferences() throws { try save(preferences, file: "settings.json") }
    func saveHistory() throws { messages = Array(messages.suffix(80)); try save(messages, file: "history.json") }
}
