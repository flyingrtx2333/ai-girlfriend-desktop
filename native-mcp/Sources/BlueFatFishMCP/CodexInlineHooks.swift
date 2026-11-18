import Foundation
import TOMLDecoder

public enum CodexInlineHooks {
    private struct Configuration: Decodable { let hooks: TOMLTable? }

    public static func read(_ data: Data) throws -> [String: Any]? {
        guard let hooks = try TOMLDecoder().decode(Configuration.self, from: data).hooks else { return nil }
        var events = try Dictionary(hooks)
        events.removeValue(forKey: "state")
        return events.isEmpty ? nil : events
    }
}
