import Foundation
import TOMLDecoder

public struct CodexAutomationConfiguration: Decodable, Sendable {
    public let id: String?
    public let version: Int?
    public let name: String
    public let prompt: String
    public let rrule: String
    public let status: String?
    public let kind: String?
    public let cwds: [String]?
    public let executionEnvironment: String?
    public let targetThreadID: String?
    public let timeZone: String?
    public let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, version, name, prompt, rrule, status, kind, cwds
        case executionEnvironment = "execution_environment"
        case targetThreadID = "target_thread_id"
        case timeZone = "time_zone"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decodeIfPresent(String.self, forKey: .id)
        version = try fields.decodeIfPresent(Int.self, forKey: .version)
        name = try fields.decode(String.self, forKey: .name)
        prompt = try fields.decode(String.self, forKey: .prompt)
        rrule = try fields.decode(String.self, forKey: .rrule)
        status = try fields.decodeIfPresent(String.self, forKey: .status)
        kind = try fields.decodeIfPresent(String.self, forKey: .kind)
        cwds = try fields.decodeIfPresent([String].self, forKey: .cwds)
        executionEnvironment = try fields.decodeIfPresent(String.self, forKey: .executionEnvironment)
        targetThreadID = try fields.decodeIfPresent(String.self, forKey: .targetThreadID)
        timeZone = try fields.decodeIfPresent(String.self, forKey: .timeZone)
        if let number = try? fields.decode(Double.self, forKey: .createdAt), number.isFinite {
            createdAt = Date(timeIntervalSince1970: abs(number) >= 100_000_000_000 ? number / 1000 : number)
        } else if let text = try? fields.decode(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { createdAt = date }
            else { formatter.formatOptions.insert(.withFractionalSeconds); createdAt = formatter.date(from: text) }
        } else { createdAt = nil }
    }

    public static func read(_ data: Data) throws -> Self { try TOMLDecoder().decode(Self.self, from: data) }
}
