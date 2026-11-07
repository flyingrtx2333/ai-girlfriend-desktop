import Foundation

@MainActor final class AgentHookHTTP {
    static let placeholder = AgentHookCredentials.placeholder
    private let credentials: AgentHookCredentials
    init(credentials: AgentHookCredentials) { self.credentials = credentials }
    static func id(_ file: URL, _ event: String, _ group: Int, _ handler: Int) -> String {
        AgentFiles.hash(Data((file.standardizedFileURL.path + "#\(event)#\(group)#\(handler)").utf8))
    }
    static func endpoint(_ value: String?) throws -> URL {
        guard let value, value.utf8.count < 8192, let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw PetError("HTTP Hook 需要有效的 HTTP/HTTPS 地址，不包含用户名或密码") }
        return url
    }
    static func validateHeaders(_ value: Any?, templates: Bool = true) throws {
        guard let value else { return }
        guard let headers = value as? [String: String], headers.count <= 32 else { throw PetError("HTTP Headers 需要字符串对象，不超过 32 项") }
        let forbidden: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "proxy-authorization", "proxy-connection", "upgrade", "expect"]
        var bytes = 0
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.count <= 100, name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !forbidden.contains(name.lowercased()), !value.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }), value.utf8.count <= 16_000 else { throw PetError("HTTP Header 名称或值无效") }
            if templates && value != placeholder { _ = try variables(value) }
            bytes += name.utf8.count + value.utf8.count
        }
        guard bytes <= 64_000, Set(headers.keys.map { $0.lowercased() }).count == headers.count else { throw PetError("HTTP Headers 重复或超过 64KB") }
    }
    static func allowedEnvironment(_ value: Any?) throws -> [String]? {
        guard let value else { return nil }
        guard let names = value as? [String], names.count <= 64, Set(names).count == names.count, names.allSatisfy(AgentCommand.validEnvironmentName) else { throw PetError("allowedEnvVars 需要环境变量名称数组，不超过 64 项且不能重复") }; return names
    }
    private static func variables(_ template: String) throws -> [NSTextCheckingResult] {
        let regex = try NSRegularExpression(pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}")
        let found = regex.matches(in: template, range: NSRange(template.startIndex..., in: template)), remaining = NSMutableString(string: template)
        for match in found.reversed() { remaining.replaceCharacters(in: match.range, with: "") }
        guard !String(remaining).contains("${") else { throw PetError("HTTP Header 环境变量需要 ${NAME} 格式") }; return found
    }
    private static func expand(_ headers: [String: String], allowed: [String]?) throws -> ([String: String], [String]) {
        var resolved: [String: String] = [:], secrets = Array(headers.values)
        for (header, template) in headers {
            let result = NSMutableString(string: template)
            for match in try variables(template).reversed() {
                guard let range = Range(match.range(at: 1), in: template) else { throw PetError("HTTP 环境变量格式无效") }
                let name = String(template[range])
                guard allowed?.contains(name) != false else { throw PetError("HTTP 环境变量未在 allowedEnvVars 中允许：" + name) }
                guard let pointer = getenv(name) else { throw PetError("HTTP 环境变量未设置：" + name) }
                let value = String(cString: pointer); secrets.append(value); result.replaceCharacters(in: match.range, with: value)
            }; resolved[header] = String(result)
        }
        try validateHeaders(resolved, templates: false); secrets += resolved.values
        return (resolved, secrets)
    }
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    func send(_ body: Data, hook: AgentHookDefinition, secret: String, onSecrets: ([String]) -> Void) async throws -> AgentToolResult {
        let url = try Self.endpoint(hook.url)
        let (headers, secretValues) = try Self.expand(credentials.values(hook), allowed: hook.allowedEnvVars)
        let redactions = secretValues.flatMap { value in [value] + (["Bearer ", "Basic "].first(where: value.hasPrefix).map { [String(value.dropFirst($0.count))] } ?? []) } + [secret]
        onSecrets(redactions)
        func redact(_ text: String) -> String { redactions.filter { !$0.isEmpty }.reduce(text) { text, value in text.replacingOccurrences(of: value, with: "[凭据已隐藏]") } }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = hook.timeout; config.timeoutIntervalForResource = hook.timeout; config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: hook.timeout)
        request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AgentHookHalt("HTTP Hook 响应无法读取") }
        var output = Data()
        for try await byte in bytes { try Task.checkCancellation(); output.append(byte); guard output.count <= 64_000 else { throw AgentHookHalt("HTTP Hook 响应超过 64KB") } }
        let raw = String(decoding: output, as: UTF8.self), text = redact(raw)
        guard (200...299).contains(response.statusCode) else { throw AgentHookHalt("HTTP Hook 返回 \(response.statusCode)：" + String(text.prefix(1000))) }
        guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any], ["continue", "decision", "reason", "systemMessage", "suppressOutput", "hookSpecificOutput"].contains(where: { object[$0] != nil }) || object.isEmpty else { throw AgentHookHalt("HTTP Hook 未返回有效的 HookOutput JSON") }
        return AgentToolResult(text: text, stdout: raw, exitCode: 0)
    }
}
