import Foundation
import Darwin

struct AgentHookCondition {
    let selector: String, argumentPattern: String?
    init(_ value: String) throws {
        guard !value.isEmpty, value.count <= 300, !value.contains("\0"), !value.contains("\n") else { throw PetError("if 需要工具名或 ToolName(参数通配符)，不超过 300 字") }
        var name = value, pattern: String?
        if value.hasSuffix(")") {
            for index in value.indices.reversed() where value[index] == "(" {
                let prefix = String(value[..<index])
                if !prefix.isEmpty, (try? NSRegularExpression(pattern: prefix)) != nil {
                    name = prefix; pattern = String(value[value.index(after: index)..<value.index(before: value.endIndex)]); break
                }
            }
        }
        guard (try? NSRegularExpression(pattern: name)) != nil else { throw PetError("if 工具名不是有效正则表达式") }
        selector = name; argumentPattern = pattern
    }
    func argumentMatches(_ fields: [String: Any]) -> Bool {
        guard let pattern = argumentPattern else { return true }
        guard let input = fields["tool_input"] as? [String: Any] else { return false }
        let tool = fields["tool_name"] as? String ?? ""
        let keys: [String]
        switch tool {
        case "Bash", "run_command": keys = ["command"]
        case "Read", "Write", "Edit", "read_file", "write_file", "edit_file": keys = ["file_path", "path"]
        case "Grep", "Glob", "search_files", "list_directory": keys = ["pattern", "query", "path"]
        default: keys = ["file_path", "path", "command", "pattern", "query", "url"]
        }
        guard let primary = keys.compactMap({ input[$0] as? String }).first else { return false }
        return fnmatch(pattern, primary, 0) == 0
    }
}
