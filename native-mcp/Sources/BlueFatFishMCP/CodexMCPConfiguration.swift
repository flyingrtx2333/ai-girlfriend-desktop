import Foundation
import TOMLDecoder

public struct CodexMCPConfiguration: Decodable, Sendable {
    public let command: String?
    public let args: [String]
    public let cwd: String?
    public let url: String?
    public let environmentKeys: [String]
    public let headerKeys: [String]
    public let hasBearerToken: Bool
    public let needsAuthorizationReview: Bool
    public let timeoutSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case command, args, cwd, url, env, auth, oauth
        case envVars = "env_vars"
        case headers = "http_headers"
        case envHeaders = "env_http_headers"
        case bearer = "bearer_token_env_var"
        case headerHelper = "http_headers_helper"
        case enabledTools = "enabled_tools"
        case disabledTools = "disabled_tools"
        case toolApproval = "default_tools_approval_mode"
        case tools
        case startupTimeout = "startup_timeout_sec"
        case toolTimeout = "tool_timeout_sec"
    }
    private struct ForwardedVariable: Decodable {
        let name: String
        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) { name = string }
            else { name = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .name) }
        }
        private enum Keys: String, CodingKey { case name }
    }
    private struct Entry: Decodable {
        let value: CodexMCPConfiguration?
        init(from decoder: Decoder) throws { value = try? CodexMCPConfiguration(from: decoder) }
    }
    private struct Document: Decodable {
        let entries: [String: Entry]?
        private enum CodingKeys: String, CodingKey { case entries = "mcp_servers" }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        command = try fields.decodeIfPresent(String.self, forKey: .command)
        args = try fields.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try fields.decodeIfPresent(String.self, forKey: .cwd)
        url = try fields.decodeIfPresent(String.self, forKey: .url)
        let env = try fields.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        let forwarded = try fields.decodeIfPresent([ForwardedVariable].self, forKey: .envVars) ?? []
        environmentKeys = Set(Array(env.keys) + forwarded.map(\.name)).sorted()
        let headers = try fields.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        let envHeaders = try fields.decodeIfPresent([String: String].self, forKey: .envHeaders) ?? [:]
        headerKeys = Set(Array(headers.keys) + Array(envHeaders.keys)).sorted()
        hasBearerToken = try !(fields.decodeIfPresent(String.self, forKey: .bearer) ?? "").isEmpty
        needsAuthorizationReview = [.auth, .oauth, .headerHelper, .enabledTools, .disabledTools, .toolApproval, .tools].contains(where: fields.contains)
        timeoutSeconds = try fields.decodeIfPresent(Double.self, forKey: .toolTimeout) ?? fields.decodeIfPresent(Double.self, forKey: .startupTimeout)
    }

    public static func read(_ data: Data) throws -> [String: CodexMCPConfiguration?] {
        let document = try TOMLDecoder().decode(Document.self, from: data)
        return document.entries?.mapValues(\.value) ?? [:]
    }
}
