import Foundation

// Only names and keychain placeholders enter saved Hook definitions. Keep the
// existing HTTP account binding so upgrades can read previously saved headers.
@MainActor final class AgentHookCredentials {
    static let placeholder = "${KEYCHAIN}"
    private let profile: URL, keychain: PetKeychain
    init(profile: URL, keychain: PetKeychain?) {
        self.profile = profile; self.keychain = keychain ?? PetKeychain(service: "com.xjs.bluefatfish.hooks.credentials")
    }
    static func field(_ entry: [String: Any]) -> String? {
        switch entry["type"] as? String ?? "command" { case "http": return "headers"; case "command": return "env"; default: return nil }
    }
    static func validateEnvironment(_ value: Any?) throws {
        guard let value else { return }
        guard let values = value as? [String: String], values.count <= 64 else { throw PetError("env 需要字符串对象，不超过 64 项") }
        let reserved: Set<String> = ["QODER_PROJECT_DIR", "QODER_HOOK_ROOT", "BLUEFATFISH_HOOK_EVENT"]
        var count = 0
        for (name, value) in values {
            guard AgentCommand.validEnvironmentName(name), !AgentCommand.launcherEnvironment(name), !reserved.contains(name), !value.contains("\0"), value.utf8.count <= 16_000 else { throw PetError("env 名称或值无效，不能覆盖 Hook 上下文或隔离启动器") }
            count += name.utf8.count + value.utf8.count
        }
        guard count <= 64_000 else { throw PetError("env 超过 64KB") }
    }
    private static func validate(_ entry: [String: Any]) throws {
        if field(entry) == "headers" { _ = try AgentHookHTTP.endpoint(entry["url"] as? String); try AgentHookHTTP.validateHeaders(entry["headers"]) }
        else { try validateEnvironment(entry["env"]) }
    }
    private static func binding(_ entry: [String: Any]) throws -> String {
        if field(entry) == "headers" { return try AgentHookHTTP.endpoint(entry["url"] as? String).absoluteString }
        var target: [String: Any] = ["command": entry["command"] as? String ?? ""]
        if let args = entry["args"] { target["args"] = args } else if let shell = entry["shell"] { target["shell"] = shell }
        return "command:" + AgentFiles.hash(try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys]))
    }
    private func account(_ id: String, _ binding: String) -> String { AgentFiles.hash(Data((profile.standardizedFileURL.path + ":" + id + ":" + binding).utf8)) }
    private func stored(_ id: String, _ binding: String) throws -> [String: String] {
        let value = try keychain.read(account(id, binding)); if value.isEmpty { return [:] }
        guard let values = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String] else { throw PetError("Hook 凭据损坏，请重新保存") }; return values
    }
    private func transform(_ data: Data, file: URL, _ edit: (String, inout [String: Any]) throws -> Void) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], var events = object["hooks"] as? [String: Any] else { throw PetError("Hooks 配置需要 hooks 对象") }
        for event in Array(events.keys) {
            guard var groups = events[event] as? [[String: Any]] else { continue }
            for group in groups.indices {
                guard var handlers = groups[group]["hooks"] as? [[String: Any]] else { continue }
                for index in handlers.indices where Self.field(handlers[index]) != nil { try edit(AgentHookHTTP.id(file, event, group, index), &handlers[index]) }
                groups[group]["hooks"] = handlers
            }; events[event] = groups
        }
        object["hooks"] = events
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    private func rows(_ data: Data, file: URL) throws -> [(String, [String: Any])] {
        var rows: [(String, [String: Any])] = []; _ = try transform(data, file: file) { id, entry in rows.append((id, entry)) }; return rows
    }
    func mask(_ data: Data) throws -> Data {
        try transform(data, file: profile) { _, entry in
            if let field = Self.field(entry), let values = entry[field] as? [String: Any] {
                entry[field] = values.mapValues { value -> Any in value is String ? Self.placeholder : value }
            }
        }
    }
    func restoreImported(_ edited: Data, original: Data, file: URL) throws -> Data {
        let imported = try rows(original, file: file)
        return try transform(edited, file: file) { id, entry in
            guard let field = Self.field(entry), var values = entry[field] as? [String: String], let old = imported.first(where: { $0.0 == id })?.1,
                  try Self.binding(old) == Self.binding(entry), let prior = old[field] as? [String: String] else { return }
            for (name, value) in values where value == Self.placeholder { if let previous = prior[name], previous != Self.placeholder { values[name] = previous } }
            entry[field] = values
        }
    }
    func available(_ hook: AgentHookDefinition) -> Bool {
        guard let binding = try? binding(hook) else { return false }; return keychain.contains(account(hook.id, binding))
    }
    private func binding(_ hook: AgentHookDefinition) throws -> String {
        var entry: [String: Any] = ["type": hook.type, "command": hook.command]
        if let url = hook.url { entry["url"] = url }; if let args = hook.arguments { entry["args"] = args }; if let shell = hook.shell { entry["shell"] = shell }
        return try Self.binding(entry)
    }
    func values(_ hook: AgentHookDefinition) throws -> [String: String] {
        let file = URL(fileURLWithPath: hook.source), files = try AgentFiles(workspace: file.deletingLastPathComponent().path)
        let data = try files.readData(files.resolve(file.lastPathComponent), maximum: 128_000)
        guard AgentFiles.hash(data) == hook.sourceHash, let entry = try rows(data, file: file).first(where: { $0.0 == hook.id })?.1,
              try Self.binding(entry) == binding(hook), let field = Self.field(entry) else { throw AgentHookHalt("Hook 配置已变化，请重新审核") }
        try Self.validate(entry)
        let raw = entry[field] as? [String: String] ?? [:], prior = raw.values.contains(Self.placeholder) ? try stored(hook.id, Self.binding(entry)) : [:]
        return try raw.reduce(into: [:]) { result, pair in
            guard let value = pair.value == Self.placeholder ? prior[pair.key] : pair.value else { throw PetError("Hook 凭据缺失：" + pair.key) }; result[pair.key] = value
        }
    }
    // Roll back keychain writes when the caller cannot commit source and grants.
    func save(_ data: Data, file: URL, write: (Data, Set<String>) throws -> Void) throws -> Set<String> {
        let files = try? AgentFiles(workspace: file.deletingLastPathComponent().path)
        let oldData = files.flatMap { try? $0.readData($0.resolve(file.lastPathComponent), maximum: 128_000) }
        let oldRows = try oldData.map { try rows($0, file: file) } ?? []
        var changes: [(String, String, String)] = [], changedIDs = Set<String>()
        let normalized = try transform(data, file: file) { id, entry in
            try Self.validate(entry); guard let field = Self.field(entry) else { return }
            let binding = try Self.binding(entry), prior = try stored(id, binding), supplied = entry[field] as? [String: String] ?? [:]
            let old = try oldRows.first { row in guard row.0 == id else { return false }; return try Self.binding(row.1) == binding }?.1[field] as? [String: String] ?? [:]
            var values: [String: String] = [:]
            for (name, value) in supplied {
                if value == Self.placeholder {
                    guard let previous = prior[name] ?? old[name], previous != Self.placeholder else { throw PetError("Hook 凭据未配置：" + name) }; values[name] = previous
                } else { values[name] = value }
            }
            let key = account(id, binding), before = try keychain.read(key), after = values.isEmpty ? "" : String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
            if before != after { changes.append((key, before, after)); changedIDs.insert(id) }
            if !supplied.isEmpty { entry[field] = supplied.mapValues { _ in Self.placeholder } }
        }
        let remaining = try rows(normalized, file: file)
        for (id, entry) in oldRows {
            let binding = try Self.binding(entry)
            guard try !remaining.contains(where: { row in guard row.0 == id else { return false }; return try Self.binding(row.1) == binding }) else { continue }
            let key = account(id, binding), before = try keychain.read(key)
            if !before.isEmpty { changes.append((key, before, "")); changedIDs.insert(id) }
        }
        var written: [(String, String)] = []
        do {
            for (key, before, after) in changes { try keychain.write(after, account: key); written.append((key, before)) }
            try write(normalized, changedIDs)
        } catch { for (key, before) in written.reversed() { try? keychain.write(before, account: key) }; throw error }
        return changedIDs
    }
    func clear(_ hook: AgentHookDefinition) throws { try keychain.write("", account: account(hook.id, binding(hook))) }
}
