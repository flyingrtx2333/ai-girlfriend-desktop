import Foundation

enum AgentQuotedCommand {
    static func parse(_ input: String, label: String, maximumBytes: Int = 4096) throws -> (name: String, arguments: String) {
        var escaped = false
        for index in input.indices.dropFirst() {
            let character = input[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                let end = input.index(after: index), rest = input[end...]
                guard rest.isEmpty || rest.first?.isWhitespace == true,
                      let name = try? JSONDecoder().decode(String.self, from: Data(input[..<end].utf8)),
                      !name.isEmpty, name.utf8.count <= maximumBytes else { throw PetError(label + "名称或后续要求格式无效") }
                return (name, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        throw PetError(label + "名称的引号尚未结束")
    }
}
