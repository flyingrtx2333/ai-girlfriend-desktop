import Foundation
import Security
import Darwin

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
    var screenObservationEnabled = false
    var screenObservationInterval = 300.0
    var screenQuietUntil: Date?
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
    let configurationFile: URL?
    let migrateLegacy: Bool
    init(service: String, legacyService: String? = nil, configurationFile: URL? = nil, migrateLegacy: Bool = true) {
        self.service = service; self.legacyService = legacyService
        self.configurationFile = configurationFile ?? (service == "com.xjs.bluefatfish.credentials" ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("BlueFatFish/credentials.json") : nil)
        self.migrateLegacy = migrateLegacy
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
    // File previews stay masked; legacy Keychain previews read metadata only.
    func preview(_ account: String) -> String? {
        if let configurationFile {
            do {
                if let value = try PetCredentialConfig(file: configurationFile).value(account) { return value.isEmpty ? nil : TokenPreview.mask(value) }
            } catch { return "配置读取失败" }
            guard migrateLegacy else { return nil }
        }
        if let item = attributes(account) {
            if let data = item[kSecAttrGeneric as String] as? Data, let text = String(data: data, encoding: .utf8) { return text }
            return "已保存"
        }
        if let legacyService, attributes(account, service: legacyService) != nil { return "已保存" }
        return nil
    }
    func read(_ account: String) throws -> String {
        if let configurationFile {
            return try PetCredentialConfig(file: configurationFile).read(account) { migrateLegacy ? try readKeychain(account) : "" }
        }
        return try readKeychain(account)
    }
    private func readKeychain(_ account: String) throws -> String {
        if let value = try secret(account) { return value }
        if let legacyService {
            do {
                if let value = try secret(account, service: legacyService) {
                    // Copy only when macOS already permits access. Never alter
                    // the old item's ACL or delete it during migration.
                    if configurationFile == nil { try? write(value, account: account) }; return value
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
        if let configurationFile { try PetCredentialConfig(file: configurationFile).write(value, account: account); return }
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
                item[kSecAttrLabel as String] = "蓝色大肥鱼 · \(account.hasPrefix("mcp-") ? "MCP" : account == "chat" ? "对话" : "语音")"
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = changed }
        }
        guard status == errSecSuccess else { throw PetError("Token 未保存，请解锁后重试。") }
    }
}

// Model/voice credentials use a separate plaintext configuration so ordinary
// preference saves and model request serialization never carry API keys.
struct PetCredentialConfig {
    let file: URL
    private struct Document: Codable { var version = 1; var tokens: [String: String] = [:] }
    private func bytes() throws -> (Data?, mode_t?) {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return (nil, nil) }
        guard fd >= 0 else { throw PetError("API Key 配置无法读取，请检查 credentials.json。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 131_072 else { throw PetError("API Key 配置不是有效的普通文件。") }
        let data = try handle.read(upToCount: 131_073) ?? Data()
        guard data.count <= 131_072 else { throw PetError("API Key 配置过大。") }
        return (data, info.st_mode)
    }
    private func document(_ data: Data?) throws -> Document {
        guard let data else { return Document() }
        guard let value = try? JSONDecoder().decode(Document.self, from: data), value.version == 1 else { throw PetError("API Key 配置格式无效，原文件已保留。") }
        return value
    }
    func value(_ account: String) throws -> String? { try document(bytes().0).tokens[account] }
    func read(_ account: String, legacy: () throws -> String) throws -> String {
        if let saved = try value(account) { return saved }
        let old: String
        do { old = try legacy() }
        catch { throw PetError("旧 API Key 无法读取，请在设置中重新填写并保存。") }
        if !old.isEmpty { try write(old, account: account) }
        return old
    }
    func write(_ value: String?, account: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (before, mode) = try bytes()
        guard mode == nil || mode! & 0o200 != 0 else { throw PetError("API Key 配置为只读，未保存。") }
        var next = try document(before)
        // Empty entries intentionally prevent a removed key being re-imported.
        next.tokens[account] = value
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 131_072 else { throw PetError("API Key 配置过大，未保存。") }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".credentials-" + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError("API Key 配置无法写入。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard try bytes().0 == before else { throw PetError("API Key 配置已被修改，请重试。") }
        guard rename(temporary.path, file.path) == 0 else { throw PetError("API Key 配置未保存，请检查目录权限。") }
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
                               legacyService: testing ? nil : "com.xjs.bluefatfish", configurationFile: directory.appendingPathComponent("credentials.json"), migrateLegacy: !testing)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !testing { for account in ["chat", "voice"] { _ = try? keychain.read(account) } }
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
