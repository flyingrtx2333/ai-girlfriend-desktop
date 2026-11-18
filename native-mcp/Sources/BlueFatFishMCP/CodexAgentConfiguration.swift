import Foundation
import TOMLDecoder

public struct CodexAgentConfiguration: Decodable, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let model: String?
    public let features: [String: Bool]
    public let sandboxMode: String?
    public let otherFields: [String]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        name = try fields.decode(String.self, forKey: Key(stringValue: "name"))
        description = try fields.decode(String.self, forKey: Key(stringValue: "description"))
        instructions = try fields.decode(String.self, forKey: Key(stringValue: "developer_instructions"))
        model = try fields.decodeIfPresent(String.self, forKey: Key(stringValue: "model"))
        features = try fields.decodeIfPresent([String: Bool].self, forKey: Key(stringValue: "features")) ?? [:]
        sandboxMode = try fields.decodeIfPresent(String.self, forKey: Key(stringValue: "sandbox_mode"))
        otherFields = fields.allKeys.map(\.stringValue).filter {
            !["name", "description", "developer_instructions", "model", "features", "sandbox_mode"].contains($0)
        }.sorted()
    }

    public static func read(_ data: Data) throws -> Self {
        try TOMLDecoder().decode(Self.self, from: data)
    }
}
