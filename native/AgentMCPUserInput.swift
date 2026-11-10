import Foundation
import CoreFoundation

struct AgentMCPUserInput {
    enum Action: String { case accept, decline, cancel }
    struct Option { var value: String; var title: String }
    struct Field {
        enum Kind: String { case string, integer, number, boolean, array }
        let key: String, title: String, detail: String, kind: Kind, required: Bool
        let options: [Option], initial: Any?
        private let minimum: Double?, maximum: Double?, minCount: Int, maxCount: Int
        private let format: String?, pattern: NSRegularExpression?

        init(key: String, schema: [String: Any], required: Bool) throws {
            guard !key.isEmpty, key.utf8.count <= 120, key.rangeOfCharacter(from: .controlCharacters) == nil,
                  let type = schema["type"] as? String, let kind = Kind(rawValue: type) else { throw PetError("连接器请求了不支持的字段类型") }
            self.key = key; self.kind = kind; self.required = required
            title = try Self.label(schema["title"], limit: 120) ?? key
            detail = try Self.label(schema["description"], limit: 1200) ?? ""
            let credentialWords = ["password", "passphrase", "apikey", "accesstoken", "refreshtoken", "bearertoken", "clientsecret", "privatekey", "paymentcredential", "creditcard", "密码", "密钥", "访问令牌"]
            let identifier = (key + " " + title).lowercased().filter { $0.isLetter || $0.isNumber }
            guard !credentialWords.contains(where: identifier.contains),
                  !["token", "secret", "otp", "pin", "cvv"].contains(key.lowercased()),
                  schema["writeOnly"] == nil, schema["format"] as? String != "password" else { throw PetError("表单不能索取凭据，请使用网页确认") }
            let common: Set<String> = ["type", "title", "description", "default"]
            let allowed: Set<String>
            switch kind {
            case .string: allowed = ["enum", "enumNames", "oneOf", "minLength", "maxLength", "format", "pattern"]
            case .integer, .number: allowed = ["minimum", "maximum"]
            case .boolean: allowed = []
            case .array: allowed = ["items", "minItems", "maxItems", "uniqueItems"]
            }
            guard Set(schema.keys).isSubset(of: common.union(allowed)) else { throw PetError("字段「\(title)」包含不支持的限制") }
            if kind == .array {
                guard let items = schema["items"] as? [String: Any], Set(items.keys).isSubset(of: ["type", "enum", "anyOf"]),
                      items["type"] == nil || items["type"] as? String == "string",
                      schema["uniqueItems"] == nil || Self.boolean(schema["uniqueItems"]) != nil else { throw PetError("多选字段格式无效") }
                options = try Self.choices(items, titled: "anyOf", mustExist: true)
            } else {
                options = kind == .string ? try Self.choices(schema, titled: "oneOf", mustExist: false) : []
            }
            minimum = try Self.bound(schema["minimum"]); maximum = try Self.bound(schema["maximum"])
            guard minimum == nil || maximum == nil || minimum! <= maximum! else { throw PetError("字段「\(title)」的数值范围无效") }
            let cap = kind == .array ? options.count : 4096
            minCount = try Self.count(schema[kind == .array ? "minItems" : "minLength"], default: 0, limit: cap)
            maxCount = min(cap, try Self.count(schema[kind == .array ? "maxItems" : "maxLength"], default: cap, limit: Int.max))
            guard minCount <= maxCount else { throw PetError("字段「\(title)」的长度范围无效") }
            format = try Self.label(schema["format"], limit: 24)
            guard format.map({ ["email", "uri", "date", "date-time"].contains($0) }) ?? true else { throw PetError("字段「\(title)」的格式不支持") }
            if let expression = try Self.label(schema["pattern"], limit: 256) { pattern = try NSRegularExpression(pattern: expression) }
            else { pattern = nil }
            initial = schema["default"]
            if let initial { try validate(initial) }
        }
        private static func label(_ raw: Any?, limit: Int) throws -> String? {
            guard let raw else { return nil }
            guard let text = raw as? String, text.utf8.count <= limit else { throw PetError("字段说明格式无效或过长") }
            return text
        }
        private static func choices(_ schema: [String: Any], titled: String, mustExist: Bool) throws -> [Option] {
            let list: [Option]
            if let raw = schema[titled] {
                guard schema["enum"] == nil, schema["enumNames"] == nil, let values = raw as? [[String: Any]] else { throw PetError("选项定义冲突") }
                list = try values.map { value in
                    guard Set(value.keys) == ["const", "title"], let id = try label(value["const"], limit: 1024),
                          let title = try label(value["title"], limit: 120), !title.isEmpty else { throw PetError("带标题的选项格式无效") }
                    return Option(value: id, title: title)
                }
            } else if let raw = schema["enum"] {
                guard let values = raw as? [String] else { throw PetError("选项必须是字符串") }
                let names = schema["enumNames"] as? [String]
                guard schema["enumNames"] == nil || names?.count == values.count else { throw PetError("选项标题与值不匹配") }
                list = values.enumerated().map { Option(value: $0.element, title: names?[$0.offset] ?? $0.element) }
            } else {
                guard !mustExist, schema["enumNames"] == nil else { throw PetError("缺少选项") }
                return []
            }
            guard (1...64).contains(list.count), Set(list.map(\.value)).count == list.count,
                  list.allSatisfy({ $0.value.utf8.count <= 1024 && $0.title.utf8.count <= 256 }) else { throw PetError("选项重复、过长或超过64项") }
            return list
        }
        static func boolean(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        private static func bound(_ value: Any?) throws -> Double? {
            guard let value else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw PetError("数值限制无效") }
            return number.doubleValue
        }
        private static func count(_ value: Any?, default fallback: Int, limit: Int) throws -> Int {
            guard let value else { return fallback }
            guard let number = value as? NSNumber, boolean(value) == nil, let count = Int(number.stringValue), (0...limit).contains(count) else { throw PetError("长度限制无效") }
            return count
        }
        func number(_ text: String) throws -> NSNumber {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let invalid = PetError("请为「\(title)」填写有效的" + (kind == .integer ? "整数" : "数字"))
            guard text.utf8.count <= 80,
                  let number = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? NSNumber,
                  Self.boolean(number) == nil else { throw invalid }
            try validate(number)
            return number
        }
        func validate(_ value: Any) throws {
            let invalid = PetError("「\(title)」不符合连接器要求")
            switch kind {
            case .boolean:
                guard Self.boolean(value) != nil else { throw invalid }
            case .integer, .number:
                guard let number = try Self.bound(value), abs(number) <= 9_007_199_254_740_991,
                      kind != .integer || number.rounded(.towardZero) == number,
                      number >= (minimum ?? -.infinity), number <= (maximum ?? .infinity) else { throw invalid }
            case .array:
                guard let values = value as? [String], (minCount...maxCount).contains(values.count), Set(values).count == values.count,
                      Set(values).isSubset(of: Set(options.map(\.value))) else { throw invalid }
            case .string:
                guard let text = value as? String, text.utf8.count <= 16_384, (minCount...maxCount).contains(text.unicodeScalars.count),
                      options.isEmpty || options.contains(where: { $0.value == text }), validFormat(text) else { throw invalid }
                if let pattern {
                    let deadline = ContinuousClock.now.advanced(by: .milliseconds(40)); var matched = false
                    pattern.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)) { hit, _, stop in
                        if hit != nil { matched = true; stop.pointee = true }
                        if ContinuousClock.now > deadline { stop.pointee = true }
                    }
                    guard matched else { throw invalid }
                }
            }
        }
        private func validFormat(_ value: String) -> Bool {
            switch format {
            case "email": return value.range(of: #"^[^@\s]+@[^@\s]+$"#, options: .regularExpression) != nil
            case "uri": return !value.contains(where: \.isWhitespace) && URL(string: value, encodingInvalidCharacters: false)?.scheme != nil
            case "date":
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
            case "date-time":
                let formatter = ISO8601DateFormatter()
                guard value.range(of: #"^\d{4}-\d\d-\d\d[Tt]\d\d:\d\d:\d\d(?:\.\d+)?(?:[Zz]|[+-]\d\d:\d\d)$"#, options: .regularExpression) != nil else { return false }
                formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                return formatter.date(from: value.uppercased()) != nil
            default: return true
            }
        }
    }
    let id = UUID().uuidString, received = Date()
    let taskID: String, sessionID: String, serverName: String, destination: String
    let message: String, fields: [Field], url: URL?, urlID: String?

    init(data: Data, taskID: String, sessionID: String, serverName: String, destination: String) throws {
        guard data.count <= 64_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 6000 else { throw PetError("连接器问询格式无效或过长") }
        self.taskID = taskID; self.sessionID = sessionID; self.serverName = serverName; self.destination = destination; self.message = message
        switch object["mode"] as? String ?? "form" {
        case "form":
            guard let schema = object["requestedSchema"] as? [String: Any], schema["type"] as? String == "object",
                  let properties = schema["properties"] as? [String: [String: Any]], properties.count <= 32 else { throw PetError("连接器表单必须包含不超过32个简单字段") }
            let required = schema["required"] as? [String] ?? []
            guard schema["required"] == nil || schema["required"] is [String], Set(required).count == required.count,
                  Set(required).isSubset(of: Set(properties.keys)) else { throw PetError("连接器表单的必填字段无效") }
            fields = try properties.keys.sorted().map { try Field(key: $0, schema: properties[$0]!, required: required.contains($0)) }
            url = nil; urlID = nil
        case "url":
            guard let raw = object["url"] as? String, raw.utf8.count <= 4000, !raw.contains(where: \.isWhitespace),
                  let address = URL(string: raw, encodingInvalidCharacters: false), let host = address.host?.lowercased(), !host.isEmpty,
                  address.user == nil, address.password == nil,
                  address.scheme?.lowercased() == "https" || (address.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
                  let id = object["elicitationId"] as? String, !id.isEmpty, id.utf8.count <= 200,
                  id.rangeOfCharacter(from: .controlCharacters) == nil else { throw PetError("连接器网页地址无效；只允许 HTTPS 或本机 HTTP") }
            fields = []; url = address; urlID = id
        default: throw PetError("未知的连接器问询方式")
        }
    }
    static func response(_ action: Action, values: [String: Any]? = nil) throws -> Data {
        var payload: [String: Any] = ["action": action.rawValue]
        if action == .accept, let values { payload["content"] = values }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= 64_000 else { throw PetError("回复超过64KB") }
        return data
    }
    func response(_ action: Action, values: [String: Any]) throws -> Data {
        guard action == .accept, url == nil else { return try Self.response(action) }
        guard Set(values.keys).isSubset(of: Set(fields.map(\.key))) else { throw PetError("表单字段已变化") }
        for field in fields {
            if let value = values[field.key] { try field.validate(value) }
            else if field.required { throw PetError("请填写「\(field.title)」") }
        }
        return try Self.response(.accept, values: values)
    }
}

@MainActor final class AgentMCPUserInputs {
    private final class Pending {
        let request: AgentMCPUserInput, current: () -> Bool, continuation: CheckedContinuation<Data, Never>
        var expires: Task<Void, Never>?
        init(_ request: AgentMCPUserInput, current: @escaping () -> Bool, continuation: CheckedContinuation<Data, Never>) {
            self.request = request; self.current = current; self.continuation = continuation
        }
    }
    private var pending: [String: Pending] = [:]
    private static let cancelled = Data(#"{"action":"cancel"}"#.utf8)
    var onChange: (() -> Void)?
    var onResponse: ((AgentMCPUserInput, AgentMCPUserInput.Action) -> Void)?
    var requests: [AgentMCPUserInput] { pending.values.map(\.request).sorted { $0.received < $1.received } }
    func first(taskID: String) -> AgentMCPUserInput? { requests.first { $0.taskID == taskID } }

    func wait(_ request: AgentMCPUserInput, current: @escaping () -> Bool) async -> Data {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, current(), pending.count < 16,
                      !pending.values.contains(where: { $0.request.sessionID == request.sessionID }) else { continuation.resume(returning: Self.cancelled); return }
                let value = Pending(request, current: current, continuation: continuation)
                pending[request.id] = value
                value.expires = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)); self?.cancel(request.id) } catch {}
                }
                onChange?()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(request.id) } })
    }
    func respond(taskID: String, id: String, action: AgentMCPUserInput.Action, values: [String: Any] = [:], openURL: ((URL) -> Bool)? = nil) throws {
        guard let value = pending[id], value.request.taskID == taskID else { throw PetError("问询已结束或不属于当前任务") }
        guard value.current() else { cancel(id); throw PetError("任务或连接已变化，未提交回复") }
        let data = try value.request.response(action, values: values)
        if action == .accept, let url = value.request.url {
            guard openURL?(url) == true else { throw PetError("未能打开确认网页，请重试或取消") }
        }
        finish(id, data: data, action: action)
    }
    func cancelSession(_ sessionID: String) {
        for id in pending.values.filter({ $0.request.sessionID == sessionID }).map({ $0.request.id }) { cancel(id) }
    }
    private func cancel(_ id: String) { finish(id, data: Self.cancelled, action: .cancel) }
    private func finish(_ id: String, data: Data, action: AgentMCPUserInput.Action) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.expires?.cancel(); value.continuation.resume(returning: data)
        onResponse?(value.request, action); onChange?()
    }
}
